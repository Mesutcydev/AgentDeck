//
//  WireProtocolTests.swift
//  SharedTests — AgentDeck
//
//  §9 wire protocol v1 tests: frame codec, Ed25519 signing rule, size
//  limit, timestamp tolerance, replay cache, seq/ack tracking, and the
//  normative known-answer vectors.
//
//  Known-answer methodology: CryptoKit Ed25519 signing is hedged
//  (randomized) per Apple platform security behavior — same key + same
//  message yields different signatures per call; verification is plain
//  RFC 8032. The vectors therefore pin (a) the exact canonical bytes and
//  (b) a fixed RFC 8032 signature — produced with an independent
//  implementation (PyNaCl/libsodium) — that MUST verify over those bytes.
//  Any canonicalization drift (key order, escaping, whitespace, integer
//  forms) makes the hardcoded signature stop verifying: the test fails
//  loudly, on both platforms (SPEC §9). See ADR-0007.
//

import CryptoKit
import Foundation
import Testing
@testable import Shared

// MARK: - Shared fixtures

enum WireTestFixtures {
    /// Test-only private key seed 0x01...0x20 (never a real credential).
    static let seed = Data((1...32).map { UInt8($0) })

    static var privateKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: seed) }
    }

    static let publicKeyHex = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"

    static func hexToData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return Data() }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    static func makeFrame(
        type: FrameType = .sessionEvent,
        seq: UInt64 = 1,
        ack: UInt64 = 0,
        timestamp: Int64 = 1_752_793_200_000,
        payload: JSONValue = .object([("payloadV", .int(1))])
    ) -> Frame {
        Frame(
            type: type,
            id: UUID(uuidString: "A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5E6") ?? UUID(),
            seq: seq,
            ack: ack,
            timestamp: timestamp,
            nonce: Data((0..<16).map { UInt8($0) }),
            payload: payload
        )
    }
}

// MARK: - Known-answer vectors

@Suite("§9 known-answer vectors")
struct KnownAnswerVectorTests {
    /// Vector 1 — full frame: cursor, unicode payload, negative integer,
    /// mixed value types. Canonical bytes and RFC 8032 signature pinned.
    @Test("vector 1: canonical bytes and signature")
    func vector1() throws {
        let sessionUUID = try #require(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"))
        let frame = Frame(
            type: .sessionEvent,
            id: try #require(UUID(uuidString: "A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5E6")),
            seq: 7,
            ack: 6,
            cursor: EventCursor(sessionID: SessionID(uuid: sessionUUID), lastEventSequence: 42),
            timestamp: 1_752_793_200_000,
            nonce: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33,
                         0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB]),
            payload: .object([
                ("payloadV", .int(1)),
                ("text", .string("héllo 😀\nworld")),
                ("count", .int(-3)),
                ("flags", .array([.bool(true), .null]))
            ])
        )

        let expectedCanonical = #"{"ack":6,"cursor":{"lastEventSequence":42,"sessionID":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"},"id":"a1a2a3a4-b1b2-c1c2-d1d2-e1e2e3e4e5e6","nonce":"3q2+7wARIjNEVWZ3iJmquw==","payload":{"count":-3,"flags":[true,null],"payloadV":1,"text":"héllo 😀\nworld"},"seq":7,"ts":1752793200000,"type":"session.event","v":1}"#
        let expectedSignatureHex = "d6e3986dd3fc098a95b0d5527743e0ba5013a74e60bd27661b1d02096c7cca70eb919a38f58ae6c3e56080f2d7fab4ae293453d1c67f4433f5c3abb508271203"

        let canonicalBytes = try frame.signingJSONValue().canonicalBytes()
        #expect(String(decoding: canonicalBytes, as: UTF8.self) == expectedCanonical)
        #expect(canonicalBytes.count == 313)

        // The fixed RFC 8032 signature (independent implementation) must
        // verify over OUR canonical bytes — drift fails here, loudly.
        let privateKey = try WireTestFixtures.privateKey
        #expect(privateKey.publicKey.rawRepresentation
            == WireTestFixtures.hexToData(WireTestFixtures.publicKeyHex))
        let expectedSignature = WireTestFixtures.hexToData(expectedSignatureHex)
        #expect(privateKey.publicKey.isValidSignature(expectedSignature, for: canonicalBytes))

        // Hedged or not, our own signing path must verify as well.
        let signed = try FrameSigner.sign(frame, with: privateKey)
        #expect(FrameVerifier.verify(signed, with: privateKey.publicKey))
    }

    /// Vector 2 — minimal frame: no cursor, empty payload, zero timestamps.
    @Test("vector 2: canonical bytes and signature")
    func vector2() throws {
        let frame = Frame(
            type: .heartbeat,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000")),
            seq: 1,
            ack: 0,
            timestamp: 0,
            nonce: Data(repeating: 0x00, count: 16),
            payload: JSONValue.object([:])
        )

        let expectedCanonical = #"{"ack":0,"id":"00000000-0000-0000-0000-000000000000","nonce":"AAAAAAAAAAAAAAAAAAAAAA==","payload":{},"seq":1,"ts":0,"type":"heartbeat","v":1}"#
        let expectedSignatureHex = "4c7740f66e23cc6c3e868a0d81762a9794d9fb6e5b242a613e3eb435a86f75acd31b50fda005d593180e4939adb2c7a2e31814760e2a53df7a63d09f5f5f2e05"

        let canonicalBytes = try frame.signingJSONValue().canonicalBytes()
        #expect(String(decoding: canonicalBytes, as: UTF8.self) == expectedCanonical)
        #expect(canonicalBytes.count == 141)

        let privateKey = try WireTestFixtures.privateKey
        let expectedSignature = WireTestFixtures.hexToData(expectedSignatureHex)
        #expect(privateKey.publicKey.isValidSignature(expectedSignature, for: canonicalBytes))
    }
}

// MARK: - Frame codec

@Suite("§9 frame codec")
struct FrameCodecTests {
    @Test("encode → decode round-trip preserves the frame")
    func roundTrip() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let frame = WireTestFixtures.makeFrame(
            seq: 3, ack: 2, timestamp: now,
            payload: .object([("payloadV", .int(1)), ("msg", .string("héllo 😀"))])
        )
        let wire = try FrameCodec.encode(frame, signingWith: key)
        let decoded = try FrameCodec.decode(wire, verifyingWith: key.publicKey, now: now)
        #expect(decoded.frame == frame)
        #expect(FrameVerifier.verify(decoded, with: key.publicKey))
    }

    @Test("wire encoding is canonical (compact, sorted keys)")
    func wireIsCanonical() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let frame = WireTestFixtures.makeFrame(timestamp: now)
        let signed = try FrameSigner.sign(frame, with: key)
        let wire = try FrameCodec.encode(signed)
        #expect(wire == (try signed.toJSONValue()).canonicalBytes())
        // Compact: no spaces or newlines anywhere.
        #expect(!wire.contains(0x20) && !wire.contains(0x0A))
    }

    @Test("verification fails for a wrong key")
    func wrongKey() throws {
        let keyA = try WireTestFixtures.privateKey
        let keyB = Curve25519.Signing.PrivateKey()
        let now = Date.unixMillisecondsNow
        let wire = try FrameCodec.encode(WireTestFixtures.makeFrame(timestamp: now), signingWith: keyA)
        #expect(throws: FrameError.invalidSignature) {
            _ = try FrameCodec.decode(wire, verifyingWith: keyB.publicKey, now: now)
        }
    }

    @Test("verification fails when the payload is tampered after signing")
    func tamperedPayload() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let wire = try FrameCodec.encode(
            WireTestFixtures.makeFrame(seq: 1, timestamp: now),
            signingWith: key
        )
        let text = String(decoding: wire, as: UTF8.self)
        let tampered = text.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":2")
        #expect(tampered != text)
        #expect(throws: FrameError.invalidSignature) {
            _ = try FrameCodec.decode(Data(tampered.utf8), verifyingWith: key.publicKey, now: now)
        }
    }

    @Test("frames larger than 1 MiB are rejected on encode and decode")
    func sizeLimit() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let bigPayload: JSONValue = .object([
            ("payloadV", .int(1)),
            ("blob", .string(String(repeating: "x", count: 1_048_576))
        )])
        let bigFrame = WireTestFixtures.makeFrame(timestamp: now, payload: bigPayload)
        #expect {
            _ = try FrameCodec.encode(bigFrame, signingWith: key)
        } throws: { error in
            guard case FrameError.frameTooLarge = error else { return false }
            return true
        }
        let oversized = Data(repeating: 0x7B, count: FrameCodec.maximumFrameSize + 1)
        #expect(throws: FrameError.frameTooLarge(size: FrameCodec.maximumFrameSize + 1,
                                                 limit: FrameCodec.maximumFrameSize)) {
            _ = try FrameCodec.decode(oversized, verifyingWith: key.publicKey, now: now)
        }
    }

    @Test("a float anywhere in the frame is a hard protocol error")
    func floatsRejected() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let wire = try FrameCodec.encode(WireTestFixtures.makeFrame(timestamp: now), signingWith: key)
        let text = String(decoding: wire, as: UTF8.self)
        let withFloat = text.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":1.0")
        #expect(throws: JSONParseError.self) {
            _ = try FrameCodec.decode(Data(withFloat.utf8), verifyingWith: key.publicKey, now: now)
        }
    }

    @Test("frames with v != 1 are rejected")
    func versionRejected() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let wire = try FrameCodec.encode(WireTestFixtures.makeFrame(timestamp: now), signingWith: key)
        let text = String(decoding: wire, as: UTF8.self)
        let v2 = text.replacingOccurrences(of: "\"v\":1}", with: "\"v\":2}")
        #expect(throws: FrameError.unsupportedVersion(2)) {
            _ = try FrameCodec.decode(Data(v2.utf8), verifyingWith: key.publicKey, now: now)
        }
    }

    @Test("non-16-byte nonces are rejected")
    func nonceLength() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let frame = Frame(
            type: .heartbeat, id: UUID(), seq: 1, ack: 0,
            timestamp: now, nonce: Data(repeating: 0x01, count: 15),
            payload: JSONValue.object([:])
        )
        #expect(throws: FrameError.invalidNonceLength(15)) {
            _ = try FrameCodec.encode(frame, signingWith: key)
        }
    }

    @Test("duplicate-key JSON in a frame is rejected")
    func duplicateKeysRejected() throws {
        let key = try WireTestFixtures.privateKey
        let now = Date.unixMillisecondsNow
        let wire = try FrameCodec.encode(WireTestFixtures.makeFrame(timestamp: now), signingWith: key)
        let text = String(decoding: wire, as: UTF8.self)
        let duplicated = text.replacingOccurrences(of: "\"ack\":0", with: "\"ack\":0,\"ack\":0")
        #expect(throws: JSONParseError.self) {
            _ = try FrameCodec.decode(Data(duplicated.utf8), verifyingWith: key.publicKey, now: now)
        }
    }
}

// MARK: - Timestamp tolerance

@Suite("§9 timestamp tolerance (±30 s)")
struct TimestampValidationTests {
    private let now: Int64 = 1_752_793_200_000

    @Test("timestamps inside the window are accepted, boundaries included")
    func insideWindow() {
        for delta: Int64 in [-30_000, -1, 0, 1, 30_000] {
            #expect(throws: Never.self) {
                try FrameCodec.validateTimestamp(now + delta, now: now)
            }
        }
    }

    @Test("timestamps outside the window are rejected")
    func outsideWindow() {
        for delta: Int64 in [-30_001, -120_000, 30_001, 120_000] {
            #expect(throws: FrameError.self) {
                try FrameCodec.validateTimestamp(now + delta, now: now)
            }
        }
    }

    @Test("decode applies the tolerance to the frame ts")
    func decodeEnforces() throws {
        let key = try WireTestFixtures.privateKey
        let staleFrame = WireTestFixtures.makeFrame(timestamp: now - 31_000)
        let wire = try FrameCodec.encode(staleFrame, signingWith: key)
        #expect(throws: FrameError.timestampOutsideTolerance(
            deltaMilliseconds: 31_000, toleranceMilliseconds: 30_000)) {
            _ = try FrameCodec.decode(wire, verifyingWith: key.publicKey, now: now)
        }
        // The same bytes decode fine with a clock inside the window.
        #expect(throws: Never.self) {
            _ = try FrameCodec.decode(wire, verifyingWith: key.publicKey, now: now - 30_500)
        }
    }
}

// MARK: - Replay cache

@Suite("§9 replay cache")
struct ReplayCacheTests {
    @Test("a nonce is accepted once and rejected on replay")
    func replayRejected() async {
        let cache = ReplayCache()
        let nonce = Data((0..<16).map { UInt8(100 + $0) })
        #expect(await cache.checkAndInsert(nonce, now: 1_000))
        #expect(await cache.checkAndInsert(nonce, now: 1_001) == false)
        #expect(await cache.count == 1)
    }

    @Test("distinct nonces are independent")
    func distinctNonces() async {
        let cache = ReplayCache()
        #expect(await cache.checkAndInsert(Data(repeating: 0x01, count: 16), now: 1_000))
        #expect(await cache.checkAndInsert(Data(repeating: 0x02, count: 16), now: 1_000))
        #expect(await cache.checkAndInsert(Data(repeating: 0x01, count: 16), now: 1_000) == false)
    }

    @Test("entries expire after their lifetime")
    func expiry() async {
        let cache = ReplayCache(entryLifetimeMilliseconds: 5_000)
        let nonce = Data(repeating: 0x03, count: 16)
        #expect(await cache.checkAndInsert(nonce, now: 10_000))
        // Inside the lifetime: still a replay.
        #expect(await cache.checkAndInsert(nonce, now: 14_999) == false)
        // A newer insert purges the expired entry; the old nonce is accepted again.
        #expect(await cache.checkAndInsert(Data(repeating: 0x04, count: 16), now: 16_000))
        #expect(await cache.checkAndInsert(nonce, now: 16_000))
    }

    @Test("at capacity the cache fails safe: new nonces are denied, replays still caught")
    func capacityFailsSafe() async {
        let cache = ReplayCache(entryLifetimeMilliseconds: 1_000_000, maximumEntries: 2)
        #expect(await cache.checkAndInsert(Data(repeating: 0x05, count: 16), now: 0))
        #expect(await cache.checkAndInsert(Data(repeating: 0x06, count: 16), now: 0))
        // Full: a brand-new nonce is denied (resend cost only)...
        #expect(await cache.checkAndInsert(Data(repeating: 0x07, count: 16), now: 0) == false)
        // ...and the recorded nonces still catch their replays.
        #expect(await cache.checkAndInsert(Data(repeating: 0x05, count: 16), now: 0) == false)
    }
}

// MARK: - Sequence tracking

@Suite("§9 seq/ack tracking")
struct SequenceTrackerTests {
    @Test("outgoing seq is monotonic from 1")
    func outgoing() {
        var tracker = SequenceTracker()
        #expect(tracker.nextOutgoingSequence == 1)
        #expect(tracker.consumeOutgoingSequence() == 1)
        #expect(tracker.consumeOutgoingSequence() == 2)
        #expect(tracker.nextOutgoingSequence == 3)
    }

    @Test("contiguous incoming seqs advance ack")
    func contiguous() throws {
        var tracker = SequenceTracker()
        #expect(tracker.currentAck == 0)
        #expect(try tracker.recordIncoming(1) == .advanced(newAck: 1))
        #expect(try tracker.recordIncoming(2) == .advanced(newAck: 2))
        #expect(tracker.currentAck == 2)
    }

    @Test("out-of-order seqs buffer and ack catches up when the gap fills")
    func gaps() throws {
        var tracker = SequenceTracker()
        #expect(try tracker.recordIncoming(1) == .advanced(newAck: 1))
        #expect(try tracker.recordIncoming(3) == .buffered(pendingGap: 2))
        #expect(try tracker.recordIncoming(4) == .buffered(pendingGap: 2))
        #expect(tracker.currentAck == 1)
        // Gap fills: ack jumps over the buffered run.
        #expect(try tracker.recordIncoming(2) == .advanced(newAck: 4))
        #expect(tracker.currentAck == 4)
    }

    @Test("duplicates and already-acked seqs do not move ack")
    func duplicates() throws {
        var tracker = SequenceTracker()
        #expect(try tracker.recordIncoming(1) == .advanced(newAck: 1))
        #expect(try tracker.recordIncoming(3) == .buffered(pendingGap: 2))
        #expect(try tracker.recordIncoming(1) == .duplicate)
        #expect(try tracker.recordIncoming(3) == .duplicate)
        #expect(tracker.currentAck == 1)
    }

    @Test("seq 0 is a protocol error (monotonic from 1)")
    func zeroRejected() {
        var tracker = SequenceTracker()
        #expect(throws: FrameError.invalidSequence(0)) {
            _ = try tracker.recordIncoming(0)
        }
    }

    @Test("the out-of-order buffer is bounded")
    func bufferBound() throws {
        var tracker = SequenceTracker(maximumBuffered: 2)
        #expect(try tracker.recordIncoming(2) == .buffered(pendingGap: 1))
        #expect(try tracker.recordIncoming(3) == .buffered(pendingGap: 1))
        #expect(throws: FrameError.invalidSequence(4)) {
            _ = try tracker.recordIncoming(4)
        }
    }
}
