//
//  TLSCertificate.swift
//  Shared — AgentDeck
//
//  The companion's TLS credential (§13.4): a P-256 ECDSA key pair in the
//  Keychain plus a self-signed X.509 certificate over it (DER writer from
//  Phase 3's SelfSignedCertificate machinery, ECDSA variant).
//
//  ADR-0008 (endpoint binding): an Ed25519 private key cannot become a
//  SecKey/SecIdentity on Apple platforms (probe-verified 2026-07-17:
//  SecKeyCreateWithData → paramErr), so the TLS certificate cannot carry
//  the Ed25519 identity key directly. Binding therefore runs per §13.4's
//  "or be signed by it" clause: the identity key SIGNS an attestation
//  over the TLS public key during pairing, and the client pins the TLS
//  public-key hash — a certificate first seen after pairing is never
//  trusted.
//

import CryptoKit
import Foundation
import Security

public enum TLSCertificateError: Error, Equatable {
    case keychainError(OSStatus)
    case identityNotFound
    case certificateFailed(String)
}

/// A device's TLS credential: SecIdentity for the listener plus the
/// public key hash clients pin.
/// @unchecked Sendable: the wrapped SecIdentity is an immutable
/// CoreFoundation object (read-only after creation).
public struct TLSIdentity: @unchecked Sendable {
    /// SecIdentity is an opaque CoreFoundation type; safe to pass between
    /// threads (immutable).
    public let identity: SecIdentity
    /// SHA-256 hex of the X9.63 public key — what peers pin at pairing.
    public let publicKeyHash: String
    /// The X9.63 (0x04‖x‖y) public key bytes.
    public let publicKey: Data

    public init(identity: SecIdentity, publicKeyHash: String, publicKey: Data) {
        self.identity = identity
        self.publicKeyHash = publicKeyHash
        self.publicKey = publicKey
    }
}

#if os(macOS)
/// Creates and stores the device's TLS key pair + self-signed cert.
///
/// Storage design (probe-verified): every generation gets a UNIQUE
/// application tag for its key pair; a generic-password item records the
/// current tag and the cert DER. Identities are rebuilt via
/// `SecIdentityCreateWithCertificate` (matches the key by public key).
/// Unique tags sidestep ambiguous same-tag keychain reads observed on
/// macOS — rotation never touches a stale key. Ed25519 keys cannot back
/// a SecIdentity (ADR-0008), hence the P-256 TLS key.
public struct TLSIdentityStore: Sendable {
    private let service: String

    public init(service: String = "\(ProductNaming.logSubsystem).tls-identity") {
        self.service = service
    }

    private var account: String { "tls-identity" }

    /// Loads the stored TLS identity, or generates + stores a fresh one.
    public func loadOrCreate() throws -> TLSIdentity {
        if let existing = try load() {
            return existing
        }
        return try generateAndStore()
    }

    /// Generates a fresh P-256 key pair + self-signed certificate and
    /// makes it current; the previous generation's key pair is deleted
    /// (rotation forces re-pairing).
    @discardableResult
    public func generateAndStore() throws -> TLSIdentity {
        let previousTag = try storedRecord()?.keyTag
        let newTag = "\(service).\(UUID().uuidString)"

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(newTag.utf8),
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Data(newTag.utf8),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TLSCertificateError.certificateFailed(
                "SecKeyCreateRandomKey: \(String(describing: error?.takeRetainedValue()))"
            )
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?,
              let p256Private = try? P256.Signing.PrivateKey(x963Representation: privateData),
              let p256Public = try? P256.Signing.PublicKey(x963Representation: publicData) else {
            throw TLSCertificateError.certificateFailed("key read-back failed")
        }
        let der = try SelfSignedCertificate.ecdsaP256(
            commonName: ProductNaming.name,
            publicKey: p256Public,
            signWith: p256Private,
            notBefore: Date(timeIntervalSinceNow: -300),
            notAfter: Date(timeIntervalSinceNow: 10 * 365 * 86_400),
            serial: UInt64(Date().timeIntervalSince1970)
        )
        try storeRecord(StoredRecord(keyTag: newTag, certificateDER: der))
        if let previousTag {
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data(previousTag.utf8)
            ] as CFDictionary)
        }
        guard let identity = try buildIdentity() else {
            throw TLSCertificateError.identityNotFound
        }
        return identity
    }

    /// Loads the stored identity (nil if never generated or key removed).
    public func load() throws -> TLSIdentity? {
        try buildIdentity()
    }

    /// Deletes the current key pair + stored record (data wipe).
    public func delete() throws {
        if let record = try storedRecord() {
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data(record.keyTag.utf8)
            ] as CFDictionary)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    // MARK: - Record persistence

    private struct StoredRecord {
        let keyTag: String
        let certificateDER: Data

        var encoded: Data {
            var data = Data()
            let tag = Data(keyTag.utf8)
            data.append(UInt8(tag.count))
            data.append(tag)
            data.append(certificateDER)
            return data
        }

        static func decode(_ data: Data) -> StoredRecord? {
            guard let tagLength = data.first, data.count > Int(tagLength) + 1 else { return nil }
            guard let tag = String(data: data.dropFirst().prefix(Int(tagLength)), encoding: .utf8) else {
                return nil
            }
            return StoredRecord(keyTag: tag, certificateDER: data.dropFirst(Int(tagLength) + 1))
        }
    }

    private func storeRecord(_ record: StoredRecord) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = record.encoded
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TLSCertificateError.keychainError(status)
        }
    }

    private func storedRecord() throws -> StoredRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TLSCertificateError.keychainError(status)
        }
        return StoredRecord.decode(data)
    }

    /// Rebuilds the TLS identity: cert from the stored DER, private key
    /// located by SecIdentityCreateWithCertificate via public-key match.
    private func buildIdentity() throws -> TLSIdentity? {
        guard let record = try storedRecord(),
              let certificate = SecCertificateCreateWithData(nil, record.certificateDER as CFData) else {
            return nil
        }
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess,
              let identity,
              let publicKey = SecCertificateCopyKey(certificate),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicData.count == 65 else {
            return nil
        }
        return TLSIdentity(
            identity: identity,
            publicKeyHash: Self.sha256Hex(publicData),
            publicKey: publicData
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

#if os(macOS)
extension SelfSignedCertificate {
    /// Builds a self-signed X.509 v3 certificate (DER) over a P-256 ECDSA
    /// key pair. Same minimal cert shape as the Ed25519 variant.
    public static func ecdsaP256(
        commonName: String,
        publicKey: P256.Signing.PublicKey,
        signWith privateKey: P256.Signing.PrivateKey,
        notBefore: Date,
        notAfter: Date,
        serial: UInt64
    ) throws -> Data {
        // ecPublicKey 1.2.840.10045.2.1 + prime256v1 1.2.840.10045.3.1.7
        let spkiAlgorithm = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
                + DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        )
        // ecdsa-with-SHA256 1.2.840.10045.4.3.2
        let signatureAlgorithm = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        )
        let name = DER.sequence(DER.set(
            DER.sequence(DER.oid([0x55, 0x04, 0x03]) + DER.utf8String(commonName))
        ))
        let tbs = DER.sequence(
            DER.explicitTag(0, DER.integer(2))
                + DER.integer(serial)
                + signatureAlgorithm
                + name
                + DER.sequence(DER.utcTime(notBefore) + DER.utcTime(notAfter))
                + name
                + DER.sequence(
                    spkiAlgorithm
                        + DER.bitString(publicKey.x963Representation)
                )
        )
        let signature = try privateKey.signature(for: tbs)
        return DER.sequence(
            tbs
                + signatureAlgorithm
                + DER.bitString(signature.derRepresentation)
        )
    }
}
#endif
