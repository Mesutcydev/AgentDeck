//
//  PairingModelTests.swift
//  SharedTests — AgentDeck
//
//  §13.2 pairing model tests: QR payload exactness, offer lifecycle
//  (expiry, single-use), verification phrase determinism, message
//  round-trips.
//

import CryptoKit
import Foundation
import Testing
@testable import Shared

@Suite("§13.2 QR payload")
struct PairingQRPayloadTests {
    private func makePayload() -> PairingQRPayload {
        PairingQRPayload(
            deviceID: DeviceID(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()),
            publicKeyFingerprint: String(repeating: "ab", count: 32),
            endpoint: PeerEndpoint(host: "192.168.1.20", port: 47_777),
            nonce: Data((0..<16).map { UInt8($0 + 1) })
        )
    }

    @Test("encoded form contains EXACTLY the six §13.2 fields")
    func exactFieldSet() throws {
        let text = try makePayload().encoded()
        let object = try #require(JSONParser.parse(text).objectValue)
        #expect(Set(object.keys) == PairingQRPayload.exactFieldSet)
        #expect(object["v"] == .int(1))
        #expect(object["protocolVersion"] == .int(1))
    }

    @Test("encode → decode round-trips")
    func roundTrip() throws {
        let payload = makePayload()
        #expect(try PairingQRPayload.decode(payload.encoded()) == payload)
    }

    @Test("extra fields are rejected (nothing beyond §13.2)")
    func extraFieldRejected() throws {
        let text = try makePayload().encoded()
        let tampered = text.replacingOccurrences(of: "\"v\":1}", with: "\"v\":1,\"extra\":\"nope\"}")
        #expect(throws: PairingQRPayloadError.unexpectedField("extra")) {
            _ = try PairingQRPayload.decode(tampered)
        }
    }

    @Test("missing fields, wrong versions, bad nonces are rejected")
    func malformedRejected() throws {
        let text = try makePayload().encoded()
        #expect(throws: (any Error).self) {
            _ = try PairingQRPayload.decode(text.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"))
        }
        #expect(throws: (any Error).self) {
            _ = try PairingQRPayload.decode("{\"v\":1}")
        }
        #expect(throws: PairingQRPayloadError.invalidNonceLength(8)) {
            _ = try PairingQRPayload(
                deviceID: .random(),
                publicKeyFingerprint: String(repeating: "cd", count: 32),
                endpoint: PeerEndpoint(host: "h"),
                nonce: Data(count: 8)
            ).encoded()
        }
        #expect(throws: PairingQRPayloadError.invalidFingerprint) {
            _ = try PairingQRPayload.decode(
                text.replacingOccurrences(of: String(repeating: "ab", count: 32), with: String(repeating: "AB", count: 32))
            )
        }
    }

    @Test("endpoint parsing")
    func endpoints() {
        #expect(PeerEndpoint("mac.local:47777") == PeerEndpoint(host: "mac.local", port: 47_777))
        #expect(PeerEndpoint("192.168.1.1:8000") == PeerEndpoint(host: "192.168.1.1", port: 8000))
        #expect(PeerEndpoint("noport") == nil)
        #expect(PeerEndpoint("h:notaport") == nil)
        #expect(PeerEndpoint(":47777") == nil)
        #expect(PeerEndpoint(host: "h").description == "h:47777")
    }
}

@Suite("§13.2 pairing offer lifecycle")
struct PairingOfferTests {
    private func makeManager() throws -> PairingOfferManager {
        let identity = DeviceIdentity(
            deviceID: .random(),
            publicKey: Curve25519.Signing.PrivateKey().publicKey
        )
        return PairingOfferManager(identity: identity, endpoint: PeerEndpoint(host: "mac.local"))
    }

    @Test("offers carry the identity fingerprint and a 128-bit nonce")
    func offerContents() async throws {
        let manager = try makeManager()
        let offer = await manager.createOffer(now: 10_000)
        #expect(offer.payload.nonce.count == 16)
        #expect(offer.payload.publicKeyFingerprint.count == 64)
        #expect(offer.payload.endpoint == PeerEndpoint(host: "mac.local"))
        #expect(offer.expiresAt - offer.createdAt == 120_000)
        #expect(offer.remainingSeconds(now: 10_000) == 120)
        #expect(offer.remainingSeconds(now: 129_500) == 0)
    }

    @Test("nonce consumption: accepted once, then alreadyUsed")
    func singleUse() async throws {
        let manager = try makeManager()
        let offer = await manager.createOffer(now: 10_000)
        let nonce = offer.payload.nonce
        guard case .accepted = await manager.consume(nonce: nonce, now: 11_000) else {
            Issue.record("first consumption must succeed")
            return
        }
        #expect(await manager.consume(nonce: nonce, now: 12_000) == .alreadyUsed)
    }

    @Test("expired nonces are rejected after 120 seconds")
    func expiry() async throws {
        let manager = try makeManager()
        let offer = await manager.createOffer(now: 10_000)
        #expect(await manager.consume(nonce: offer.payload.nonce, now: 10_000 + 119_999) != .expired)
        let second = await manager.createOffer(now: 10_000)
        #expect(await manager.consume(nonce: second.payload.nonce, now: 10_000 + 120_000) == .expired)
    }

    @Test("unknown nonces and superseded offers are rejected")
    func unknownAndSuperseded() async throws {
        let manager = try makeManager()
        let first = await manager.createOffer(now: 10_000)
        let second = await manager.createOffer(now: 11_000)
        #expect(await manager.consume(nonce: Data(count: 16), now: 12_000) == .unknown)
        #expect(await manager.consume(nonce: first.payload.nonce, now: 12_000) == .unknown,
                "creating a new offer invalidates the previous one")
        guard case .accepted = await manager.consume(nonce: second.payload.nonce, now: 12_000) else {
            Issue.record("current offer must consume")
            return
        }
    }

    @Test("cancelling the offer rejects its nonce")
    func cancel() async throws {
        let manager = try makeManager()
        let offer = await manager.createOffer(now: 10_000)
        await manager.cancelOffer()
        #expect(await manager.consume(nonce: offer.payload.nonce, now: 11_000) == .unknown)
    }
}

@Suite("§13.2 verification phrase")
struct VerificationPhraseTests {
    @Test("the word list has exactly 256 unique words")
    func wordListIntegrity() {
        #expect(VerificationPhrase.wordList.count == 256)
        #expect(Set(VerificationPhrase.wordList).count == 256)
    }

    @Test("phrase is deterministic and six words")
    func determinism() {
        let server = Data((0..<32).map { UInt8($0) })
        let client = Data((0..<32).map { UInt8(100 + $0) })
        let code = Data((0..<32).map { UInt8(200 + ($0 % 56)) })
        let first = VerificationPhrase.words(
            serverPublicKey: server, clientPublicKey: client, verificationCode: code
        )
        let second = VerificationPhrase.words(
            serverPublicKey: server, clientPublicKey: client, verificationCode: code
        )
        #expect(first == second)
        #expect(first.count == 6)
        for word in first {
            #expect(VerificationPhrase.wordList.contains(word))
        }
        // Swapping any input changes the phrase.
        let swapped = VerificationPhrase.words(
            serverPublicKey: client, clientPublicKey: server, verificationCode: code
        )
        #expect(swapped != first)
    }
}

@Suite("§13.2 handshake message wire forms")
struct PairingMessageTests {
    @Test("all handshake payloads round-trip with payloadV")
    func roundTrips() throws {
        let hello = PairingHello(
            nonce: Data(count: 16), clientDeviceID: .random(),
            clientPublicKey: Data(count: 32), clientDisplayName: "iPhone",
            protocolVersion: 1
        )
        #expect(try PairingHello(jsonValue: hello.toJSONValue()) == hello)

        let accept = PairingAccept(
            serverDeviceID: .random(), serverPublicKey: Data(count: 32),
            serverDisplayName: "Mac", protocolVersion: 1, verificationCode: Data(count: 32),
            tlsPublicKeyHash: String(repeating: "ef", count: 32), attestation: Data(count: 64)
        )
        #expect(try PairingAccept(jsonValue: accept.toJSONValue()) == accept)

        let reject = PairingReject(reason: .nonceExpired)
        #expect(try PairingReject(jsonValue: reject.toJSONValue()) == reject)

        let confirm = PairingConfirm(deviceID: .random(), confirmed: true)
        #expect(try PairingConfirm(jsonValue: confirm.toJSONValue()) == confirm)

        let complete = PairingComplete(protocolVersion: 1, grantedCapabilities: [.sessions, .approvals])
        #expect(try PairingComplete(jsonValue: complete.toJSONValue()) == complete)
    }

    @Test("unknown payloadV is rejected")
    func versionRejected() {
        #expect(throws: JSONValueDecodingError.unsupportedPayloadVersion(found: 99, supported: 1)) {
            _ = try PairingHello(jsonValue: .object([("payloadV", .int(99))]))
        }
    }

    @Test("session.resume payload round-trips with and without cursor")
    func resumePayload() throws {
        let empty = SessionResumeRequest(lastCursor: nil)
        #expect(try SessionResumeRequest(jsonValue: empty.toJSONValue()) == empty)

        let cursor = EventCursor(sessionID: .random(), lastEventSequence: 42)
        let request = SessionResumeRequest(lastCursor: cursor)
        #expect(try SessionResumeRequest(jsonValue: request.toJSONValue()) == request)
    }
}
