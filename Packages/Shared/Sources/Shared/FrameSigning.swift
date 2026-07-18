//
//  FrameSigning.swift
//  Shared — AgentDeck
//
//  Ed25519 signing and verification for §9 frames via CryptoKit
//  (Curve25519.Signing). Device identity keys are generated and stored by
//  the pairing layer (Phase 3, SPEC §13.1); this file is pure cryptography.
//

import CryptoKit
import Foundation

/// Signs §9 frames. `sig` covers the JCS canonical UTF-8 encoding of the
/// frame with `sig` absent (SPEC §9 signing rule, normative).
public enum FrameSigner {
    public static func sign(
        _ frame: Frame,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedFrame {
        let signingBytes = try frame.signingJSONValue().canonicalBytes()
        let signature = try privateKey.signature(for: signingBytes)
        return SignedFrame(frame: frame, signature: signature)
    }
}

/// Verifies §9 frames against a peer's public key.
public enum FrameVerifier {
    /// Re-serializes the frame (without `sig`) through the canonicalizer and
    /// verifies the Ed25519 signature. A peer whose canonical encoding
    /// differs in ANY way (key order, escaping, whitespace) fails here —
    /// which is exactly what the known-answer vectors pin (SPEC §9).
    public static func verify(
        _ signed: SignedFrame,
        with publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        guard let signingBytes = try? signed.frame.signingJSONValue().canonicalBytes() else {
            return false
        }
        return publicKey.isValidSignature(signed.signature, for: signingBytes)
    }
}
