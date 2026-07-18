//
//  TransportSecurity.swift
//  Shared — AgentDeck
//
//  §13.4 transport security on Network.framework: TLS + WebSocket
//  parameters for both roles, with endpoint binding (SPEC v2.1, ADR-0008):
//   - Server presents the device's P-256 TLS identity.
//   - Client verify block pins the presented certificate's public-key
//     hash to the value recorded at pairing (or, during pairing itself,
//     captures it for attestation — the §9 attestation then binds it to
//     the QR identity fingerprint).
//  A certificate first seen after pairing is never trusted.
//

import CryptoKit
import Foundation
import Network
import Security

public enum TransportSecurityError: Error, Equatable {
    case identityUnavailable
    case peerCertificateUnavailable
    case publicKeyUnavailable
}

public enum TransportSecurity {
    /// TLS 1.3 minimum; no compression (§13.4: only after security review).
    private static func applyBaseline(_ tlsOptions: NWProtocolTLS.Options) {
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv13
        )
    }

    /// Server parameters: TLS with the device's TLS identity + WebSocket.
    /// Mutual authentication is at the §9 layer (identity-signed frames);
    /// TLS client certificates are not used in v1.
    #if os(macOS)
    public static func serverParameters(tlsIdentity: TLSIdentity) throws -> NWParameters {
        guard let secIdentity = sec_identity_create(tlsIdentity.identity) else {
            throw TransportSecurityError.identityUnavailable
        }
        let tlsOptions = NWProtocolTLS.Options()
        applyBaseline(tlsOptions)
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions, secIdentity
        )
        return tcpParameters(tls: tlsOptions)
    }
    #endif

    /// Client parameters with endpoint binding.
    /// - Parameter pinnedPublicKeyHash: the TLS public-key hash recorded at
    ///   pairing. When non-nil, the verify block REJECTS any other
    ///   certificate (post-pairing cert swaps are never trusted). When nil
    ///   (pairing bootstrap only), any certificate is accepted and its
    ///   public-key hash is reported via `capturedPublicKeyHash` for the
    ///   §9 attestation check.
    /// - Parameter capturedPublicKeyHash: receives the presented key hash
    ///   during bootstrap.
    public static func clientParameters(
        pinnedPublicKeyHash: String?,
        capturedPublicKeyHash: (@Sendable (String) -> Void)? = nil
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        applyBaseline(tlsOptions)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, completion in
                guard let hash = publicKeyHash(of: trust) else {
                    completion(false)
                    return
                }
                if let pinnedPublicKeyHash {
                    completion(hash == pinnedPublicKeyHash)
                } else {
                    capturedPublicKeyHash?(hash)
                    completion(true)
                }
            },
            DispatchQueue(label: "\(ProductNaming.logSubsystem).tls-verify")
        )
        return tcpParameters(tls: tlsOptions)
    }

    /// SHA-256 hex of the peer certificate's public key (X9.63 form).
    public static func publicKeyHash(of trust: sec_trust_t) -> String? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let certificate = chain.first,
              let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tcpParameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        return NWParameters(tls: tls, tcp: tcpOptions)
    }
}
