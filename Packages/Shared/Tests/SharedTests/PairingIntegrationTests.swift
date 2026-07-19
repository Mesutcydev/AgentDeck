//
//  PairingIntegrationTests.swift
//  SharedTests — AgentDeck
//
//  §13 end-to-end pairing and transport tests over the loopback interface.
//  These run on macOS because the server side (TLS listener + PeerListener)
//  is macOS-only; the client engine is the same code used by the iOS app.
//

import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import Shared

#if os(macOS)
/// A confirmation delegate that always approves — used for headless tests.
private actor AutoConfirmingDelegate: PairingConfirmationDelegate {
    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        true
    }
}

/// A confirmation delegate that always rejects — used for cancellation tests.
private actor AutoRejectingDelegate: PairingConfirmationDelegate {
    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        false
    }
}

@Suite("§13 pairing integration (loopback)", .serialized)
struct PairingIntegrationTests {
    private func runIntegrationTest(_ body: @Sendable @escaping () async throws -> Void) async throws {
        try await IntegrationTestQueue.async(body)
    }

    private func makeTLSIdentity() throws -> TLSIdentity {
        let service = "com.agentdeck.tests.tls.integration.\(UUID().uuidString)"
        var lastError: Error?
        for attempt in 0..<8 {
            do {
                return try TLSIdentityStore(service: service).loadOrCreate()
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
            }
        }
        throw lastError!
    }

    private func makeServer(
        repository: SQLiteSessionStore,
        maxPairedClients: Int = 3,
        confirmationDelegate: (any PairingConfirmationDelegate)? = nil
    ) async throws -> (engine: PairingServerEngine, identity: DeviceIdentity, privateKey: Curve25519.Signing.PrivateKey, tls: TLSIdentity) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: privateKey.publicKey)
        let tls = try makeTLSIdentity()
        var config = PairingServerEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            tlsIdentity: tls,
            displayName: "Test Mac",
            listenPort: 0,
            advertisedHost: "127.0.0.1"
        )
        config.maxPairedClients = maxPairedClients
        config.handshakeTimeoutMilliseconds = 5_000
        config.confirmationTimeoutMilliseconds = 5_000
        let engine = PairingServerEngine(
            configuration: config,
            repository: repository,
            confirmationDelegate: confirmationDelegate ?? AutoConfirmingDelegate()
        )
        try await engine.start()
        return (engine, identity, privateKey, tls)
    }

    private func makeClient(
        repository: SQLiteSessionStore,
        maxPairedMacs: Int = 5,
        confirmationDelegate: (any PairingConfirmationDelegate)? = nil
    ) async throws -> (engine: PairingClientEngine, identity: DeviceIdentity, privateKey: Curve25519.Signing.PrivateKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: privateKey.publicKey)
        var config = PairingClientEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            displayName: "Test iPhone"
        )
        config.maxPairedMacs = maxPairedMacs
        config.handshakeTimeoutMilliseconds = 5_000
        let engine = PairingClientEngine(
            configuration: config,
            repository: repository,
            confirmationDelegate: confirmationDelegate ?? AutoConfirmingDelegate()
        )
        return (engine, identity, privateKey)
    }

    private func waitForBoundPort(on server: PairingServerEngine) async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = await server.boundPort {
                return port
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PairingError.listenerUnavailable
    }

    // MARK: - Pairing flow

    @Test("full QR pairing flow over 127.0.0.1")
    func fullPairingFlow() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let offer = await server.engine.makeOffer()

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let (outcome, connection) = try await client.engine.pair(qrPayload: offer.payload)

        guard case .paired(let peerID) = outcome else {
            Issue.record("expected paired outcome, got \(outcome)")
            return
        }
        #expect(peerID == server.identity.deviceID)
        #expect(connection != nil)

        // Both sides persisted the peer.
        let serverPeers = try await server.engine.pairedPeers()
        #expect(serverPeers.contains(where: { $0.id == client.identity.deviceID && !$0.revoked }))

        let clientPeers = try await clientRepo.listDevices()
        #expect(clientPeers.contains(where: { $0.id == server.identity.deviceID && !$0.revoked }))

        await server.engine.stop()
        if let connection {
            await connection.close()
        }
        }
    }

    @Test("paired client reconnects without a fresh QR offer")
    func reconnect() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server.engine)
        let offer = await server.engine.makeOffer()

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let (outcome, _) = try await client.engine.pair(qrPayload: offer.payload)
        guard case .paired = outcome else {
            Issue.record("pairing failed before reconnect test")
            return
        }

        let peer = try #require(await clientRepo.listDevices().first)
        let connection = try await client.engine.connectToPairedPeer(
            peer,
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port)
        )
        #expect(await connection.closeReason == nil)

        await server.engine.stop()
        await connection.close()
        }
    }

    @Test("revoked device cannot reconnect")
    func revocationBlocksReconnect() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server.engine)
        let offer = await server.engine.makeOffer()

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let (outcome, _) = try await client.engine.pair(qrPayload: offer.payload)
        guard case .paired = outcome else {
            Issue.record("pairing failed before revocation test")
            return
        }

        try await server.engine.revokePeer(client.identity.deviceID)

        // Server-side record is revoked.
        let serverPeers = try await server.engine.pairedPeers()
        #expect(serverPeers.contains(where: { $0.id == client.identity.deviceID && $0.revoked }))

        // Reconnect is rejected.
        let peer = try #require(await clientRepo.listDevices().first)
        await #expect(throws: PairingError.rejectedByPeer(.revoked)) {
            _ = try await client.engine.connectToPairedPeer(
                peer,
                endpoint: PeerEndpoint(host: "127.0.0.1", port: port)
            )
        }

        await server.engine.stop()
        }
    }

    @Test("revoked device can explicitly re-pair with a fresh QR offer")
    func revokedDeviceCanExplicitlyRepair() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        _ = try await waitForBoundPort(on: server.engine)

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let firstOffer = await server.engine.makeOffer()
        let (firstOutcome, firstConnection) = try await client.engine.pair(qrPayload: firstOffer.payload)
        guard case .paired = firstOutcome else {
            Issue.record("initial pairing failed")
            return
        }

        try await server.engine.revokePeer(client.identity.deviceID)
        if let firstConnection { await firstConnection.close() }

        // A fresh single-use offer plus mutual phrase confirmation is an
        // explicit authorization, unlike the blocked silent reconnect.
        let freshOffer = await server.engine.makeOffer()
        let (repairOutcome, repairConnection) = try await client.engine.pair(qrPayload: freshOffer.payload)
        guard case .paired(let deviceID) = repairOutcome else {
            Issue.record("explicit re-pair failed: \(repairOutcome)")
            return
        }
        #expect(deviceID == server.identity.deviceID)
        let peers = try await server.engine.pairedPeers()
        #expect(peers.contains(where: { $0.id == client.identity.deviceID && !$0.revoked }))

        if let repairConnection { await repairConnection.close() }
        await server.engine.stop()
        }
    }

    @Test("known device can scan a fresh QR after its local pairing record was lost")
    func knownDeviceCanExplicitlyRepair() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        _ = try await waitForBoundPort(on: server.engine)

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let firstOffer = await server.engine.makeOffer()
        let (firstOutcome, firstConnection) = try await client.engine.pair(qrPayload: firstOffer.payload)
        guard case .paired = firstOutcome else {
            Issue.record("initial pairing failed")
            return
        }
        if let firstConnection { await firstConnection.close() }

        // Simulates reinstall/reset on iOS while the Mac still remembers the
        // same device identity. A non-zero nonce means explicit QR pairing,
        // not the zero-nonce reconnect shortcut.
        try await clientRepo.deleteDevice(id: server.identity.deviceID)
        let freshOffer = await server.engine.makeOffer()
        let (repairOutcome, repairConnection) = try await client.engine.pair(qrPayload: freshOffer.payload)
        guard case .paired(let deviceID) = repairOutcome else {
            Issue.record("explicit re-pair failed: \(repairOutcome)")
            return
        }
        #expect(deviceID == server.identity.deviceID)
        #expect(try await clientRepo.listDevices().count == 1)

        if let repairConnection { await repairConnection.close() }
        await server.engine.stop()
        }
    }

    @Test("client-side rejection cancels pairing")
    func clientRejection() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        _ = try await waitForBoundPort(on: server.engine)
        let offer = await server.engine.makeOffer()

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(
            repository: clientRepo,
            confirmationDelegate: AutoRejectingDelegate()
        )
        let (outcome, connection) = try await client.engine.pair(qrPayload: offer.payload)

        #expect(outcome == .cancelledByUser)
        #expect(connection == nil)

        await server.engine.stop()
        }
    }

    @Test("server-side device limit rejects new pairings")
    func deviceLimit() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo, maxPairedClients: 1)
        _ = try await waitForBoundPort(on: server.engine)

        let firstRepo = try SQLiteSessionStore.inMemory()
        let firstClient = try await makeClient(repository: firstRepo)
        let firstOffer = await server.engine.makeOffer()
        let (firstOutcome, _) = try await firstClient.engine.pair(qrPayload: firstOffer.payload)
        guard case .paired = firstOutcome else {
            Issue.record("first pairing must succeed")
            return
        }

        let secondRepo = try SQLiteSessionStore.inMemory()
        let secondClient = try await makeClient(repository: secondRepo)
        let secondOffer = await server.engine.makeOffer()
        let (secondOutcome, _) = try await secondClient.engine.pair(qrPayload: secondOffer.payload)
        guard case .rejected(let reason) = secondOutcome else {
            Issue.record("expected deviceLimitReached, got \(secondOutcome)")
            return
        }
        #expect(reason == .deviceLimitReached)

        await server.engine.stop()
        }
    }

    // MARK: - Session resume

    @Test("session.resume replays events after the client's cursor")
    func sessionResumeReplay() async throws {
        try await runIntegrationTest {
        // Pair using the same flow as fullPairingFlow (proven green).
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let offer = await server.engine.makeOffer()

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await makeClient(repository: clientRepo)
        let (outcome, optionalConnection) = try await client.engine.pair(qrPayload: offer.payload)
        guard case .paired = outcome, let connection = optionalConnection else {
            Issue.record("pairing failed before resume test: \(outcome)")
            return
        }

        let session = SessionRecord(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            state: .runningCommand,
            createdAt: 1,
            updatedAt: 1
        )
        try await serverRepo.insertSession(session)
        for sequence in UInt64(1)...3 {
            try await serverRepo.insertEvent(EventRecord(
                id: .random(),
                sessionID: session.id,
                sequence: sequence,
                timestamp: Int64(sequence),
                confidence: .native,
                kind: "rawOutput",
                payload: .object([
                    ("payloadV", .int(1)),
                    ("text", .string("event \(sequence)")),
                    ("reason", .string("test"))
                ])
            ))
        }

        try await connection.send(
            type: .sessionResume,
            payload: SessionResumeRequest(lastCursor: EventCursor(
                sessionID: session.id,
                lastEventSequence: 1
            )).toJSONValue()
        )

        var received: [UInt64] = []
        let deadline = Date().addingTimeInterval(5)
        while received.count < 2 && Date() < deadline {
            let frame = try await nextFrame(from: connection, timeout: 1_000)
            if frame.frame.type == .sessionEvent {
                let event = try AgentEvent(jsonValue: frame.frame.payload)
                received.append(event.sequence)
            }
        }
        #expect(received.sorted() == [2, 3])

        await server.engine.stop()
        await connection.close()
        }
    }
}
#endif

#if os(macOS)
// MARK: - Raw loopback client (crafted frames; TLS like the real client)

/// A raw §9 client for adversarial cases the real client cannot produce
/// (wrongly-signed frames, garbage nonces). Uses the same TLS parameters
/// as PairingClientEngine so the listener accepts it.
private final class PairingAuditRawClient: @unchecked Sendable {
    let connection: NWConnection
    private var nextSeq: UInt64 = 1
    private let cancelled = Mutex(false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    init(port: UInt16) {
        connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 47_777),
            using: TransportSecurity.clientParameters(pinnedPublicKeyHash: nil)
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let shouldResume = resumed.withLock { value -> Bool in
                        if value { return false }; value = true; return true
                    }
                    if shouldResume { continuation.resume() }
                case .failed(let error):
                    self.cancelled.withLock { $0 = true }
                    let shouldResume = resumed.withLock { value -> Bool in
                        if value { return false }; value = true; return true
                    }
                    if shouldResume { continuation.resume(throwing: error) }
                case .waiting(let error):
                    // A peer that closes mid-handshake (e.g. the rate limiter
                    // dropping us) leaves the connection parked in `.waiting`
                    // — no `.failed` ever fires. These loopback tests never
                    // expect recovery, so treat waiting-with-error as terminal.
                    self.cancelled.withLock { $0 = true }
                    let shouldResume = resumed.withLock { value -> Bool in
                        if value { return false }; value = true; return true
                    }
                    if shouldResume { continuation.resume(throwing: error) }
                case .cancelled:
                    self.cancelled.withLock { $0 = true }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.pairing.raw"))
        }
    }

    func send(
        type: FrameType,
        payload: JSONValue,
        signingWith key: Curve25519.Signing.PrivateKey
    ) async throws {
        let frame = Frame(
            type: type,
            seq: nextSeq,
            ack: 0,
            timestamp: Date.unixMillisecondsNow,
            nonce: Data((0..<Frame.nonceLength).map { _ in UInt8.random(in: 0...255) }),
            payload: payload
        )
        nextSeq += 1
        let body = try FrameCodec.encode(frame, signingWith: key)
        var data = Data(capacity: MemoryLayout<UInt32>.size + body.count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads one frame; nil on clean EOF, throws on transport error.
    func readFrame() async throws -> SignedFrame? {
        guard let lengthData = try await receiveExactly(MemoryLayout<UInt32>.size) else {
            return nil
        }
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0, length <= UInt32(FrameCodec.maximumFrameSize) else {
            return nil
        }
        guard let body = try await receiveExactly(Int(length)) else {
            return nil
        }
        return try FrameCodec.decodeUnverified(body, now: Date.unixMillisecondsNow)
    }

    private func receiveExactly(_ count: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func close() {
        connection.cancel()
    }

    /// Sends a pairing.hello with a fresh identity and returns it.
    @discardableResult
    func sendHello(
        nonce: Data,
        key: Curve25519.Signing.PrivateKey,
        deviceID: DeviceID = .random(),
        displayName: String = "Raw Client"
    ) async throws -> DeviceID {
        try await send(
            type: .pairingHello,
            payload: PairingHello(
                nonce: nonce,
                clientDeviceID: deviceID,
                clientPublicKey: key.publicKey.rawRepresentation,
                clientDisplayName: displayName,
                protocolVersion: PairingQRPayload.version
            ).toJSONValue(),
            signingWith: key
        )
        return deviceID
    }
}

@Suite("§13.4/§20 pairing hardening (loopback)", .serialized)
struct PairingHardeningIntegrationTests {
    private func runIntegrationTest(_ body: @Sendable @escaping () async throws -> Void) async throws {
        try await IntegrationTestQueue.async(body)
    }

    private func makeTLSIdentity() throws -> TLSIdentity {
        let service = "com.agentdeck.tests.tls.hardening.\(UUID().uuidString)"
        var lastError: Error?
        for attempt in 0..<8 {
            do {
                return try TLSIdentityStore(service: service).loadOrCreate()
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
            }
        }
        throw lastError ?? PairingError.listenerUnavailable
    }

    private func makeServer(
        repository: SQLiteSessionStore,
        configure: (inout PairingServerEngine.Configuration) -> Void = { _ in }
    ) async throws -> PairingServerEngine {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: privateKey.publicKey)
        var config = PairingServerEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            tlsIdentity: try makeTLSIdentity(),
            displayName: "Test Mac",
            listenPort: 0,
            advertisedHost: "127.0.0.1"
        )
        config.handshakeTimeoutMilliseconds = 5_000
        config.confirmationTimeoutMilliseconds = 5_000
        configure(&config)
        let engine = PairingServerEngine(
            configuration: config,
            repository: repository,
            confirmationDelegate: HardeningConfirmDelegate()
        )
        try await engine.start()
        return engine
    }

    private func waitForBoundPort(on server: PairingServerEngine) async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = await server.boundPort {
                return port
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PairingError.listenerUnavailable
    }

    @Test("pairing.confirm without a valid client signature is not acted on")
    func unsignedConfirmRejected() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server)
        let offer = await server.makeOffer()

        let clientKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let raw = PairingAuditRawClient(port: port)
        try await raw.start()
        try await raw.sendHello(nonce: offer.payload.nonce, key: clientKey)

        let accept = try #require(try await raw.readFrame())
        #expect(accept.frame.type == .pairingAccept, "hello (validly signed) is answered")

        // The confirm frame is forged: signed by a DIFFERENT key than the
        // identity presented in hello.
        try await raw.send(
            type: .pairingConfirm,
            payload: PairingConfirm(deviceID: .random(), confirmed: true).toJSONValue(),
            signingWith: wrongKey
        )

        // The server must drop the connection without completing pairing.
        let reply = try await raw.readFrame()
        #expect(reply == nil || reply?.frame.type == .pairingReject,
                "no pairing.complete may follow an unsigned confirm")
        let devices = try await serverRepo.listDevices()
        #expect(devices.isEmpty, "no peer record may persist from a forged confirm")

        raw.close()
        await server.stop()
        }
    }

    @Test("five failed pairings from one source trip the limit; the Mac-side reset clears it")
    func failureThrottle() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo) { config in
            config.pairingFailureLimit = 5
            config.pairingBackoffBaseMilliseconds = 0 // isolate pure counting
        }
        let port = try await waitForBoundPort(on: server)

        // Five failed attempts (unknown nonce) — each is answered with the
        // honest rejection...
        for _ in 0..<5 {
            let raw = PairingAuditRawClient(port: port)
            try await raw.start()
            let key = Curve25519.Signing.PrivateKey()
            try await raw.sendHello(nonce: Data(count: 16), key: key)
            let frame = try #require(try await raw.readFrame())
            #expect(frame.frame.type == .pairingReject)
            let reject = try PairingReject(jsonValue: frame.frame.payload)
            #expect(reject.reason == .unknownNonce)
            raw.close()
        }

        // ...and the sixth attempt from the same source is rate limited.
        let limited = PairingAuditRawClient(port: port)
        try await limited.start()
        try await limited.sendHello(nonce: Data(count: 16), key: Curve25519.Signing.PrivateKey())
        let limitedFrame = try #require(try await limited.readFrame())
        let limitedReject = try PairingReject(jsonValue: limitedFrame.frame.payload)
        #expect(limitedReject.reason == .rateLimited)
        limited.close()

        // Mac-side reset path: the operator clears the source.
        await server.resetPairingFailureLimit(forSource: "127.0.0.1")
        let afterReset = PairingAuditRawClient(port: port)
        try await afterReset.start()
        try await afterReset.sendHello(nonce: Data(count: 16), key: Curve25519.Signing.PrivateKey())
        let resetFrame = try #require(try await afterReset.readFrame())
        let resetReject = try PairingReject(jsonValue: resetFrame.frame.payload)
        #expect(resetReject.reason == .unknownNonce, "after reset the source is throttled no longer")
        afterReset.close()

        await server.stop()
        }
    }

    @Test("the connection limiter keys on the source endpoint and trips")
    func connectionLimiter() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo) { config in
            config.connectionAttemptLimit = 3
        }
        let port = try await waitForBoundPort(on: server)

        // Three idle connections fill the source's window...
        var held: [PairingAuditRawClient] = []
        for _ in 0..<3 {
            let raw = PairingAuditRawClient(port: port)
            try await raw.start()
            held.append(raw)
            // Let the server account for this connection before the next
            // one arrives (accept handling is concurrent).
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // ...so the fourth from the same source is rejected: the server
        // closes it during the handshake (start throws) or right after
        // (readFrame returns nil). Either outcome proves rejection.
        let fourth = PairingAuditRawClient(port: port)
        var rejected = false
        do {
            try await fourth.start()
            rejected = (try await fourth.readFrame()) == nil
        } catch {
            rejected = true
        }
        #expect(rejected, "over-limit connections are closed without service")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(held.allSatisfy { !$0.isCancelled },
                "in-limit connections stay open until the handshake timeout")

        for raw in held { raw.close() }
        fourth.close()
        await server.stop()
        }
    }
}

@Suite("§14/§20 session-serving hardening (loopback)", .serialized)
struct SessionServingIntegrationTests {
    private func runIntegrationTest(_ body: @Sendable @escaping () async throws -> Void) async throws {
        try await IntegrationTestQueue.async(body)
    }

    private func makeTLSIdentity() throws -> TLSIdentity {
        let service = "com.agentdeck.tests.tls.serving.\(UUID().uuidString)"
        var lastError: Error?
        for attempt in 0..<8 {
            do {
                return try TLSIdentityStore(service: service).loadOrCreate()
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
            }
        }
        throw lastError ?? PairingError.listenerUnavailable
    }

    private func makeClientIdentity() -> (DeviceIdentity, Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        return (DeviceIdentity(deviceID: .random(), publicKey: key.publicKey), key)
    }

    private func pairNewClient(
        server: PairingServerEngine,
        port: UInt16,
        clientRepository: SQLiteSessionStore
    ) async throws -> (engine: PairingClientEngine, identity: DeviceIdentity, connection: PeerConnection) {
        let (identity, key) = makeClientIdentity()
        var config = PairingClientEngine.Configuration(
            identity: identity,
            privateKey: key,
            displayName: "Test iPhone"
        )
        config.handshakeTimeoutMilliseconds = 5_000
        let engine = PairingClientEngine(
            configuration: config,
            repository: clientRepository,
            confirmationDelegate: HardeningConfirmDelegate()
        )
        let offer = await server.makeOffer()
        let (outcome, connection) = try await engine.pair(qrPayload: offer.payload)
        guard case .paired = outcome, let connection else {
            Issue.record("pairing failed in session-serving setup: \(outcome)")
            throw PairingError.listenerUnavailable
        }
        _ = port
        return (engine, identity, connection)
    }

    private func makeServer(
        repository: SQLiteSessionStore
    ) async throws -> PairingServerEngine {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: privateKey.publicKey)
        var config = PairingServerEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            tlsIdentity: try makeTLSIdentity(),
            displayName: "Test Mac",
            listenPort: 0,
            advertisedHost: "127.0.0.1"
        )
        config.handshakeTimeoutMilliseconds = 5_000
        config.confirmationTimeoutMilliseconds = 5_000
        let engine = PairingServerEngine(
            configuration: config,
            repository: repository,
            confirmationDelegate: HardeningConfirmDelegate()
        )
        try await engine.start()
        return engine
    }

    private func waitForBoundPort(on server: PairingServerEngine) async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = await server.boundPort {
                return port
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PairingError.listenerUnavailable
    }

    private func insertRawEvents(
        _ count: Int,
        sessionID: SessionID,
        into store: SQLiteSessionStore
    ) async throws {
        for index in 1...count {
            try await store.insertEvent(EventRecord(
                id: .random(),
                sessionID: sessionID,
                sequence: UInt64(index),
                timestamp: Int64(index),
                confidence: .native,
                kind: "rawOutput",
                payload: .object([
                    ("payloadV", .int(1)),
                    ("text", .string("event \(index)")),
                    ("reason", .string("test"))
                ])
            ))
        }
    }

    private func resumePayload(
        cursor: EventCursor,
        pageSize: Int64? = nil
    ) throws -> JSONValue {
        var object = try SessionResumeRequest(lastCursor: cursor).toJSONValue().objectValue ?? [:]
        if let pageSize {
            object["pageSize"] = .int(pageSize)
        }
        return .object(object)
    }

    @Test("device.pushToken cannot re-point another device's notifications (IDOR)")
    func pushTokenIDORRejected() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server)

        let victimRepo = try SQLiteSessionStore.inMemory()
        let victim = try await pairNewClient(server: server, port: port, clientRepository: victimRepo)
        let attackerRepo = try SQLiteSessionStore.inMemory()
        let attacker = try await pairNewClient(server: server, port: port, clientRepository: attackerRepo)

        // The attacker asserts the VICTIM's deviceID in the payload.
        let token = try #require(PushDestinationToken("attacker-token"))
        try await attacker.connection.send(
            type: .devicePushToken,
            payload: DevicePushTokenRequest(deviceID: victim.identity.deviceID, destinationToken: token).toJSONValue()
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        // The token must land on the AUTHENTICATED peer (the attacker),
        // never on the payload-asserted victim.
        let victimRecord = try #require(try await serverRepo.device(id: victim.identity.deviceID))
        #expect(victimRecord.pushDestinationToken == nil,
                "the victim's push destination is untouched by the forged payload")
        let attackerRecord = try #require(try await serverRepo.device(id: attacker.identity.deviceID))
        #expect(attackerRecord.pushDestinationToken?.rawValue == "attacker-token")

        await server.stop()
        }
    }

    @Test("session.resume paginates with cursors; the legacy envelope is unchanged")
    func resumePagination() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server)
        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await pairNewClient(server: server, port: port, clientRepository: clientRepo)

        let session = SessionRecord(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            state: .thinking,
            createdAt: 1,
            updatedAt: 1
        )
        try await serverRepo.insertSession(session)
        try await insertRawEvents(5, sessionID: session.id, into: serverRepo)

        // Page 1: two events + a hasMore marker.
        try await client.connection.send(
            type: .sessionResume,
            payload: try resumePayload(cursor: EventCursor(sessionID: session.id, lastEventSequence: 0), pageSize: 2)
        )
        var sequences: [UInt64] = []
        var marker: TransportNotice?
        for _ in 0..<3 {
            let frame = try await nextFrame(from: client.connection, timeout: 5_000)
            let event = try AgentEvent(jsonValue: frame.frame.payload)
            if case .transport(let notice) = event.payload {
                marker = notice
            } else {
                sequences.append(event.sequence)
            }
        }
        #expect(sequences == [1, 2])
        #expect(marker?.code == .resumePage)
        #expect(try marker?.metadata.boolField("hasMore") == true)
        #expect(try marker?.metadata.u64Field("lastEventSequence") == 2)

        // Page 2: events 3,4 + hasMore (a full page can't prove exhaustion).
        try await client.connection.send(
            type: .sessionResume,
            payload: try resumePayload(cursor: EventCursor(sessionID: session.id, lastEventSequence: 2), pageSize: 2)
        )
        sequences = []
        marker = nil
        for _ in 0..<3 {
            let frame = try await nextFrame(from: client.connection, timeout: 5_000)
            let event = try AgentEvent(jsonValue: frame.frame.payload)
            if case .transport(let notice) = event.payload {
                marker = notice
            } else {
                sequences.append(event.sequence)
            }
        }
        #expect(sequences == [3, 4])
        #expect(try marker?.metadata.boolField("hasMore") == true)

        // Page 3: the final event + hasMore == false.
        try await client.connection.send(
            type: .sessionResume,
            payload: try resumePayload(cursor: EventCursor(sessionID: session.id, lastEventSequence: 4), pageSize: 2)
        )
        sequences = []
        marker = nil
        for _ in 0..<2 {
            let frame = try await nextFrame(from: client.connection, timeout: 5_000)
            let event = try AgentEvent(jsonValue: frame.frame.payload)
            if case .transport(let notice) = event.payload {
                marker = notice
            } else {
                sequences.append(event.sequence)
            }
        }
        #expect(sequences == [5])
        #expect(try marker?.metadata.boolField("hasMore") == false)

        // Legacy mode (no pageSize): all five events and NO marker — the
        // next frame we read belongs to the following paged request.
        try await client.connection.send(
            type: .sessionResume,
            payload: try resumePayload(cursor: EventCursor(sessionID: session.id, lastEventSequence: 0))
        )
        var legacySequences: [UInt64] = []
        for _ in 0..<5 {
            let frame = try await nextFrame(from: client.connection, timeout: 5_000)
            let event = try AgentEvent(jsonValue: frame.frame.payload)
            if case .rawOutput = event.payload {
                legacySequences.append(event.sequence)
            }
        }
        #expect(legacySequences == [1, 2, 3, 4, 5])

        try await client.connection.send(
            type: .sessionResume,
            payload: try resumePayload(cursor: EventCursor(sessionID: session.id, lastEventSequence: 5), pageSize: 1)
        )
        let trailing = try await nextFrame(from: client.connection, timeout: 5_000)
        let trailingEvent = try AgentEvent(jsonValue: trailing.frame.payload)
        guard case .transport(let trailingNotice) = trailingEvent.payload else {
            Issue.record("legacy replay must not emit markers; expected the paged marker next, got \(trailingEvent.payload.kind)")
            return
        }
        #expect(trailingNotice.code == .resumePage)
        #expect(try trailingNotice.metadata.boolField("hasMore") == false)

        await server.stop()
        }
    }

    @Test("session.start launches through the authorized path and broadcasts; unauthorized projects are rejected")
    func sessionStartContract() async throws {
        try await runIntegrationTest {
        let serverRepo = try SQLiteSessionStore.inMemory()
        let server = try await makeServer(repository: serverRepo)
        let port = try await waitForBoundPort(on: server)

        // A stub agent the server can "launch".
        let agentID = try #require(AgentIdentifier("com.example.adapter"))
        await server.registerAgentAdapter(SessionStubAdapter(identifier: agentID))

        // An authorized project (§12.4) rooted at a real directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = try PathSafety.canonicalPath(for: directory)
        let project = ProjectRecord(
            id: .random(),
            displayName: "Authorized Project",
            canonicalPath: canonical,
            createdAt: 1
        )
        try await serverRepo.insertProject(project)

        let clientRepo = try SQLiteSessionStore.inMemory()
        let client = try await pairNewClient(server: server, port: port, clientRepository: clientRepo)

        // Happy path: the contract frame starts a session; the client
        // learns the sessionID from the broadcast session.event.
        try await client.connection.send(
            type: .sessionStart,
            payload: SessionStartRequest(
                projectID: project.id,
                agentID: agentID,
                prompt: PromptInput(text: "Summarize this repo"),
                model: "test-model"
            ).toJSONValue()
        )
        let started = try await nextFrame(from: client.connection, timeout: 5_000)
        #expect(started.frame.type == .sessionEvent)
        let startedEvent = try AgentEvent(jsonValue: started.frame.payload)
        guard case .stateChanged = startedEvent.payload else {
            Issue.record("expected the start stateChanged event, got \(startedEvent.payload.kind)")
            return
        }
        let record = try #require(try await serverRepo.session(id: startedEvent.sessionID))
        #expect(record.projectID == project.id)
        #expect(record.agent == agentID)

        // Unauthorized path: a valid command that cannot be completed is
        // rejected without taking down the secure transport.
        let unknownProjectID = ProjectID.random()
        try await client.connection.send(
            type: .sessionStart,
            payload: SessionStartRequest(
                projectID: unknownProjectID,
                agentID: agentID,
                prompt: PromptInput(text: "touch /etc/passwd")
            ).toJSONValue()
        )
        let rejected = try await nextFrame(from: client.connection, timeout: 5_000)
        #expect(rejected.frame.type == .commandError)
        let commandError = try RemoteCommandError(jsonValue: rejected.frame.payload)
        #expect(commandError.operation == FrameType.sessionStart.rawValue)
        #expect(commandError.projectID == unknownProjectID)

        // A subsequent request on the same connection still succeeds.
        try await client.connection.send(
            type: .projectList,
            payload: .object([("payloadV", .int(1))])
        )
        let projectList = try await nextFrame(from: client.connection, timeout: 5_000)
        #expect(projectList.frame.type == .projectListResponse)
        let sessions = try await serverRepo.listSessions()
        #expect(sessions.count == 1, "no session is created for an unauthorized project")
        await server.stop()
        }
    }
}

private actor HardeningConfirmDelegate: PairingConfirmationDelegate {
    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        true
    }
}
#endif
