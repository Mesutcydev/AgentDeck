//
//  FrameCodec.swift
//  Shared — AgentDeck
//
//  §9 wire codec. v1 encoding is compact JSON; the JCS canonical encoding
//  IS the wire encoding, so what is signed is byte-identical to what is
//  sent, and decoding re-canonicalizes before verifying — drift between
//  peers fails the signature, never passes silently.
//

import CryptoKit
import Foundation

public enum FrameCodec {
    /// Maximum frame size: 1 MiB (SPEC §9). Larger payloads use chunked
    /// transfer frames (later phases); this limit is a hard ceiling.
    public static let maximumFrameSize = 1_048_576

    /// Timestamp acceptance window: ±30 s (SPEC §9).
    public static let timestampToleranceMilliseconds: Int64 = 30_000

    // MARK: - Encode

    /// Signs and encodes a frame for the wire.
    /// - Throws: `FrameError.frameTooLarge` when the canonical encoding
    ///   exceeds 1 MiB; `FrameError.invalidNonceLength` for a bad nonce.
    public static func encode(
        _ frame: Frame,
        signingWith privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let signed = try FrameSigner.sign(frame, with: privateKey)
        return try encode(signed)
    }

    /// Encodes an already-signed frame.
    public static func encode(_ signed: SignedFrame) throws -> Data {
        let data = try signed.toJSONValue().canonicalBytes()
        guard data.count <= maximumFrameSize else {
            throw FrameError.frameTooLarge(size: data.count, limit: maximumFrameSize)
        }
        return data
    }

    // MARK: - Decode

    /// Parses, validates, and verifies a received frame.
    ///
    /// Order of checks (fail fast, cheapest first): size cap → strict
    /// integer-only parse → structure/version/shape → timestamp tolerance →
    /// Ed25519 signature. Replay detection (`ReplayCache`) is the caller's
    /// job once this returns a verified frame.
    ///
    /// - Parameters:
    ///   - data: raw wire bytes (must be ≤ 1 MiB).
    ///   - publicKey: the peer's verified identity key (§13.4 pinning).
    ///   - now: current time in unix ms; injectable for tests.
    public static func decode(
        _ data: Data,
        verifyingWith publicKey: Curve25519.Signing.PublicKey,
        now: Int64 = Date.unixMillisecondsNow
    ) throws -> SignedFrame {
        guard data.count <= maximumFrameSize else {
            throw FrameError.frameTooLarge(size: data.count, limit: maximumFrameSize)
        }
        let parsed = try JSONParser.parse(data)
        let signed = try SignedFrame(jsonValue: parsed)
        try validateTimestamp(signed.frame.timestamp, now: now)
        guard FrameVerifier.verify(signed, with: publicKey) else {
            throw FrameError.invalidSignature
        }
        return signed
    }

    /// Parses and validates a received frame WITHOUT signature
    /// verification — the pairing bootstrap only, where the peer key is
    /// not yet known. The handshake layer verifies the embedded keys
    /// itself (ADR-0008); post-pairing frames always go through `decode`.
    public static func decodeUnverified(
        _ data: Data,
        now: Int64 = Date.unixMillisecondsNow
    ) throws -> SignedFrame {
        guard data.count <= maximumFrameSize else {
            throw FrameError.frameTooLarge(size: data.count, limit: maximumFrameSize)
        }
        let parsed = try JSONParser.parse(data)
        let signed = try SignedFrame(jsonValue: parsed)
        try validateTimestamp(signed.frame.timestamp, now: now)
        return signed
    }

    /// §9 timestamp acceptance: |ts - now| ≤ 30 s.
    public static func validateTimestamp(
        _ timestamp: Int64,
        now: Int64,
        tolerance: Int64 = timestampToleranceMilliseconds
    ) throws {
        let delta = timestamp > now ? timestamp - now : now - timestamp
        guard delta <= tolerance else {
            throw FrameError.timestampOutsideTolerance(
                deltaMilliseconds: delta, toleranceMilliseconds: tolerance
            )
        }
    }
}

extension Date {
    /// Current time as unix milliseconds (§9 `ts` unit).
    public static var unixMillisecondsNow: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Converts a §9 `ts` value to a Date.
    public init(unixMilliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000)
    }
}
