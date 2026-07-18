//
//  PeerConnection.swift
//  Shared — AgentDeck
//
//  One §9 connection (§13.3: one TLS/TCP stream per phone–Mac pair):
//  length-prefixed signed frames over Network.framework. Owns
//  per-direction seq/ack (§9), replay cache, timestamp validation,
//  heartbeat (15 s send / 45 s peer-lost), the 1 MiB cap, and the §23
//  metrics counters. Frame SIGNATURE verification runs against the pinned
//  peer key once known; during the pairing bootstrap frames pass through
//  with structure+timestamp checks only and the handshake layer verifies
//  the embedded keys itself (ADR-0008), then pins via `setPeerPublicKey`.
//
//  ADR-0009: raw TLS/TCP with a 4-byte big-endian length prefix is used
//  instead of WebSocket because Network.framework's WebSocket server path
//  rejected the self-signed handshake in loopback tests; the wire payload
//  (JCS-canonical signed JSON) is unchanged.
//

import CryptoKit
import Foundation
import Network

public enum PeerConnectionCloseReason: Sendable, Equatable {
    case localClose
    case closedByPeer
    case peerLost
    case failed(String)
}

public actor PeerConnection {
    /// §9 heartbeat: 15 s interval; peer declared lost after 45 s silence.
    public static let defaultHeartbeatIntervalMilliseconds: UInt64 = 15_000
    public static let defaultPeerLostTimeoutMilliseconds: Int64 = 45_000

    private let connection: NWConnection
    private let localPrivateKey: Curve25519.Signing.PrivateKey
    private var peerPublicKey: Curve25519.Signing.PublicKey?
    private var tracker = SequenceTracker()
    private let replayCache = ReplayCache()
    private let counter: MetricsCounter?
    private let heartbeatIntervalMilliseconds: UInt64
    private let peerLostTimeoutMilliseconds: Int64
    private let nowProvider: @Sendable () -> Int64

    private var lastIncomingAt: Int64
    private var heartbeatTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var frameBuffer: [SignedFrame] = []
    private var frameWaiters: [CheckedContinuation<SignedFrame?, Error>] = []
    private var isReady = false
    private var isClosed = false

    public private(set) var closeReason: PeerConnectionCloseReason?

    /// Stable identifier of the connection SOURCE for rate limiting (§13.4):
    /// the remote host for host:port endpoints (source ports are ephemeral —
    /// keying on them would let every reconnect dodge the limiter), the
    /// endpoint description otherwise. A `let`, so it is readable without
    /// suspension before any TLS/handshake work runs.
    public let remoteEndpointIdentifier: String

    /// Wraps an NWConnection (client- or server-side). `start()` begins
    /// the connection; frames arrive on `frames`.
    public init(
        connection: NWConnection,
        localPrivateKey: Curve25519.Signing.PrivateKey,
        peerPublicKey: Curve25519.Signing.PublicKey? = nil,
        counter: MetricsCounter? = nil,
        heartbeatIntervalMilliseconds: UInt64 = PeerConnection.defaultHeartbeatIntervalMilliseconds,
        peerLostTimeoutMilliseconds: Int64 = PeerConnection.defaultPeerLostTimeoutMilliseconds,
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow }
    ) {
        self.connection = connection
        self.localPrivateKey = localPrivateKey
        self.peerPublicKey = peerPublicKey
        self.counter = counter
        self.heartbeatIntervalMilliseconds = heartbeatIntervalMilliseconds
        self.peerLostTimeoutMilliseconds = peerLostTimeoutMilliseconds
        self.nowProvider = nowProvider
        self.lastIncomingAt = nowProvider()
        switch connection.endpoint {
        case .hostPort(let host, _):
            self.remoteEndpointIdentifier = "\(host)"
        default:
            self.remoteEndpointIdentifier = "\(connection.endpoint)"
        }
    }

    // MARK: - Lifecycle

    /// Starts the connection and the heartbeat/monitor loops.
    public func start() {
        let queue = DispatchQueue(label: "\(ProductNaming.logSubsystem).peer-connection")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleState(state) }
        }
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            receiveNext()
            startHeartbeat()
            startMonitor()
        case .failed(let error):
            finish(.failed(error.localizedDescription))
        case .cancelled:
            finish(closeReason ?? .closedByPeer)
        default:
            break
        }
    }

    /// Waits for the connection to become ready. Call after `start()`; if
    /// the connection is already ready, returns immediately.
    public func waitForReady(timeoutMilliseconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000.0)
        while !isReady {
            if Date() >= deadline {
                throw PeerConnectionError.readyTimeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Closes the connection locally.
    public func close() {
        finish(.localClose)
    }

    private func finish(_ reason: PeerConnectionCloseReason) {
        guard !isClosed else { return }
        isClosed = true
        closeReason = reason
        heartbeatTask?.cancel()
        monitorTask?.cancel()
        connection.cancel()
        let waiters = frameWaiters
        frameWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Reads the next verified frame, suspending until one arrives or the
    /// connection closes. Multiple sequential reads on one connection are
    /// supported (handshake then session traffic).
    public func readFrame() async throws -> SignedFrame? {
        if !frameBuffer.isEmpty {
            return frameBuffer.removeFirst()
        }
        if isClosed {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            frameWaiters.append(continuation)
        }
    }

    private func deliverFrame(_ frame: SignedFrame) {
        if !frameWaiters.isEmpty {
            let waiter = frameWaiters.removeFirst()
            waiter.resume(returning: frame)
        } else {
            frameBuffer.append(frame)
        }
    }

    // MARK: - Peer key pinning

    /// Pins the peer's identity key after the pairing handshake verified
    /// it; from here on every frame is signature-verified against it.
    public func setPeerPublicKey(_ publicKey: Curve25519.Signing.PublicKey) {
        peerPublicKey = publicKey
    }

    // MARK: - Sending

    /// Builds, signs, and sends a §9 frame with a 4-byte length prefix.
    public func send(type: FrameType, payload: JSONValue, cursor: EventCursor? = nil) async throws {
        guard !isClosed else {
            throw PeerConnectionError.closed
        }
        let frame = Frame(
            type: type,
            seq: tracker.consumeOutgoingSequence(),
            ack: tracker.currentAck,
            cursor: cursor,
            timestamp: nowProvider(),
            nonce: randomNonce(),
            payload: payload
        )
        let payloadData = try FrameCodec.encode(frame, signingWith: localPrivateKey)
        guard payloadData.count <= FrameCodec.maximumFrameSize else {
            throw FrameError.frameTooLarge(size: payloadData.count, limit: FrameCodec.maximumFrameSize)
        }
        var data = Data(capacity: MemoryLayout<UInt32>.size + payloadData.count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payloadData.count).bigEndian, Array.init))
        data.append(payloadData)
        try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        checked.resume(throwing: error)
                    } else {
                        checked.resume()
                    }
                }
            )
        }
        await counter?.increment(.framesSent)
        await counter?.increment(.frameBytesSent, by: Int64(payloadData.count))
    }

    private func randomNonce() -> Data {
        Data((0..<Frame.nonceLength).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: - Receiving

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: MemoryLayout<UInt32>.size, maximumLength: MemoryLayout<UInt32>.size) { [weak self] lengthData, _, _, error in
            guard let self else { return }
            Task { await self.handleLength(lengthData, error: error) }
        }
    }

    private func handleLength(_ lengthData: Data?, error: NWError?) async {
        if let error {
            finish(.failed(error.localizedDescription))
            return
        }
        guard let lengthData, lengthData.count == MemoryLayout<UInt32>.size, !isClosed else {
            finish(.failed("length prefix unreadable"))
            return
        }
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0, length <= UInt32(FrameCodec.maximumFrameSize) else {
            finish(.failed("frame length out of range: \(length)"))
            return
        }
        connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payloadData, _, _, error in
            guard let self else { return }
            Task { await self.handlePayload(payloadData, error: error) }
        }
    }

    private func handlePayload(_ content: Data?, error: NWError?) async {
        if let error {
            finish(.failed(error.localizedDescription))
            return
        }
        guard let content, !isClosed else { return }
        lastIncomingAt = nowProvider()
        do {
            let signed = try decodeFrame(content)
            // Replay: a nonce seen before is dropped, never delivered (§9).
            guard await replayCache.checkAndInsert(signed.frame.nonce, now: nowProvider()) else {
                await counter?.increment(.framesRejectedReplay)
                receiveNext()
                return
            }
            let reception = try tracker.recordIncoming(signed.frame.seq)
            // Duplicate seq with a FRESH nonce passes the replay cache but
            // must not be delivered twice (§9 ordering); gap/buffer
            // bookkeeping is unchanged — out-of-order frames still flow.
            if case .duplicate = reception {
                await counter?.increment(.framesRejectedReplay)
                receiveNext()
                return
            }
            await counter?.increment(.framesReceived)
            await counter?.increment(.frameBytesReceived, by: Int64(content.count))
            deliverFrame(signed)
        } catch let error as FrameError {
            await countRejection(error)
        } catch {
            await counter?.increment(.framesRejectedSignature)
        }
        if !isClosed {
            receiveNext()
        }
    }

    /// Verifies the frame signature when the peer key is pinned; during
    /// the pairing bootstrap, structural + timestamp checks only (the
    /// handshake layer verifies embedded keys, ADR-0008).
    private func decodeFrame(_ data: Data) throws -> SignedFrame {
        if let peerPublicKey {
            return try FrameCodec.decode(data, verifyingWith: peerPublicKey, now: nowProvider())
        }
        return try FrameCodec.decodeUnverified(data, now: nowProvider())
    }

    private func countRejection(_ error: FrameError) async {
        switch error {
        case .frameTooLarge:
            await counter?.increment(.framesRejectedOversize)
        case .invalidSignature:
            await counter?.increment(.framesRejectedSignature)
        case .timestampOutsideTolerance:
            await counter?.increment(.framesRejectedTimestamp)
        default:
            await counter?.increment(.framesRejectedSignature)
        }
    }

    // MARK: - Heartbeat & peer-lost monitoring

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let intervalNanoseconds = (self?.heartbeatIntervalMilliseconds ?? 15_000) * 1_000_000
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard let self, !Task.isCancelled else { return }
                try? await self.send(type: .heartbeat, payload: .object([:]))
            }
        }
    }

    private func startMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.checkPeerSilence()
            }
        }
    }

    private func checkPeerSilence() {
        guard !isClosed else { return }
        let silence = nowProvider() - lastIncomingAt
        if silence > peerLostTimeoutMilliseconds {
            finish(.peerLost)
        }
    }
}

public enum PeerConnectionError: Error, Equatable {
    case closed
    case readyTimeout
}
