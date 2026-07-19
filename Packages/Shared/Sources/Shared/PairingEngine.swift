//
//  PairingEngine.swift
//  Shared — AgentDeck
//
//  §13.2/§13.3/§13.4 pairing and session connection engines.
//
//  PairingServerEngine (companion side): listens, runs the handshake
//  state machine per connection — nonce consumption (single-use, 120 s),
//  rate limits, protocol-version negotiation, device limits, attestation
//  (endpoint binding), phrase confirmation on BOTH sides, peer
//  persistence, revocation, and session.resume replay from the §12.5
//  store. Reconnecting known peers skip the QR flow (their hello carries
//  the pinned key); revoked peers are rejected and dropped.
//
//  PairingClientEngine (iOS side): connects to the QR endpoint, verifies
//  the server fingerprint + attestation + TLS hash (endpoint binding),
//  confirms the phrase, persists the peer, and reconnects pinned peers.
//
//  Local confirmation on each side is delegated (UI in the apps, fakes in
//  tests) — §13.2 mutual confirmation.
//

import CryptoKit
import Foundation
import Network

/// UI seam for §13.2 human confirmation of the verification phrase.
public protocol PairingConfirmationDelegate: Sendable {
    /// Shows the phrase + short fingerprint; returns true when the human
    /// confirms both devices show the same values.
    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool
}

public enum PairingError: Error, Equatable {
    case timeout
    case protocolViolation(String)
    case identityMismatch
    case endpointBindingMismatch
    case signatureInvalid
    case rejectedByPeer(PairingRejectReason)
    case deviceLimitReached
    case listenerUnavailable
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout:
            "The pairing request timed out. Keep both apps open and try a new QR code."
        case .protocolViolation(let detail):
            "The devices could not complete the pairing handshake (\(detail))."
        case .identityMismatch:
            "The Mac identity did not match the scanned pairing code. Generate a new code on the Mac."
        case .endpointBindingMismatch:
            "The connection did not match the secure endpoint in the pairing code."
        case .signatureInvalid:
            "The pairing signature could not be verified."
        case .rejectedByPeer(let reason):
            "The other device rejected pairing: \(reason.localizedPairingDescription)."
        case .deviceLimitReached:
            "The paired-device limit has been reached. Forget an old device and try again."
        case .listenerUnavailable:
            "The Mac pairing service is not available. Restart listening and try again."
        }
    }
}

private extension PairingRejectReason {
    var localizedPairingDescription: String {
        switch self {
        case .revoked: "this device was revoked"
        case .deviceLimitReached: "the paired-device limit was reached"
        case .rateLimited: "too many attempts; wait a moment and try again"
        case .unknownNonce, .nonceAlreadyUsed, .nonceExpired: "the QR code is no longer valid; generate a new one"
        case .protocolMismatch: "the apps use incompatible protocol versions; update both apps"
        case .cancelled: "confirmation was cancelled"
        }
    }
}

// MARK: - Server engine

#if os(macOS)
public actor PairingServerEngine {
    public struct Configuration: Sendable {
        public var identity: DeviceIdentity
        public var privateKey: Curve25519.Signing.PrivateKey
        public var tlsIdentity: TLSIdentity
        public var displayName: String
        public var listenPort: UInt16
        public var serviceName: String?
        /// The host advertised in pairing offers (e.g. LAN IP or Bonjour
        /// name). Tests use 127.0.0.1; production uses the discovered address.
        public var advertisedHost: String
        /// §13.3: up to 3 paired iOS devices per Mac.
        public var maxPairedClients: Int = 3
        /// §13.4 connection-attempt limit (per fixed window, per source).
        public var connectionAttemptLimit: Int = 30
        public var rateWindowMilliseconds: Int64 = 60_000
        /// §13.4 pairing throttle: FAILED attempts per source inside the
        /// sliding window, plus exponential backoff between failures.
        public var pairingFailureLimit: Int = 5
        public var pairingFailureWindowMilliseconds: Int64 = 600_000
        public var pairingBackoffBaseMilliseconds: Int64 = 1_000
        public var pairingBackoffMaximumMilliseconds: Int64 = 300_000
        public var handshakeTimeoutMilliseconds: UInt64 = 30_000
        public var confirmationTimeoutMilliseconds: UInt64 = 120_000
        public var nowProvider: @Sendable () -> Int64 = { Date.unixMillisecondsNow }
        public var notificationDispatch: AgentSessionOrchestrator.NotificationDispatchHandler?
        /// §29 terminal lifecycle hooks, supplied by the companion. Without
        /// them the corresponding frames are answered with an honest error
        /// event instead of being silently dropped.
        public var terminalStartHandler: (@Sendable (TerminalStartRequest) async throws -> SessionID)?
        public var terminalInputHandler: (@Sendable (SessionID, Data) async throws -> Void)?
        public var terminalResizeHandler: (@Sendable (SessionID, Int, Int) async throws -> Void)?
        public var terminalScrollbackProvider: (@Sendable (SessionID) async -> Data?)?
        /// §6 Home state sync: agent inventory provider (installed runtimes
        /// + live session counts) for `agent.list` / `agent.snapshot`.
        public var agentStateProvider: (@Sendable () async -> [AgentCardState])?
        /// §16 diff mirroring provider (DirectoryDiffGenerator in the
        /// companion); returns nil when no diff exists for the session.
        public var diffProvider: (@Sendable (SessionID, Int?) async throws -> DiffContent?)?

        public init(
            identity: DeviceIdentity,
            privateKey: Curve25519.Signing.PrivateKey,
            tlsIdentity: TLSIdentity,
            displayName: String,
            listenPort: UInt16 = PeerEndpoint.defaultPort,
            advertisedHost: String = "0.0.0.0",
            serviceName: String? = nil
        ) {
            self.identity = identity
            self.privateKey = privateKey
            self.tlsIdentity = tlsIdentity
            self.displayName = displayName
            self.listenPort = listenPort
            self.advertisedHost = advertisedHost
            self.serviceName = serviceName
        }
    }

    /// Capabilities granted to paired clients in v1.
    public static let grantedCapabilities: [PeerCapability] = [.sessions, .approvals]

    private let configuration: Configuration
    private let repository: any SessionRepository
    private let confirmationDelegate: any PairingConfirmationDelegate
    private let counter: MetricsCounter?
    private let offerManager: PairingOfferManager
    private let connectionLimiter: RateLimiter
    private let pairingFailureLimiter: FailureRateLimiter

    private var listener: PeerListener?
    private var listenerTask: Task<Void, Never>?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var liveConnections: [DeviceID: PeerConnection] = [:]
    private var sessionOrchestrator: AgentSessionOrchestrator?

    public private(set) var boundPort: UInt16?

    public init(
        configuration: Configuration,
        repository: any SessionRepository,
        confirmationDelegate: any PairingConfirmationDelegate,
        counter: MetricsCounter? = nil
    ) {
        self.configuration = configuration
        self.repository = repository
        self.confirmationDelegate = confirmationDelegate
        self.counter = counter
        self.offerManager = PairingOfferManager(
            identity: configuration.identity,
            endpoint: PeerEndpoint(host: configuration.advertisedHost, port: configuration.listenPort)
        )
        self.connectionLimiter = RateLimiter(
            limit: configuration.connectionAttemptLimit,
            windowMilliseconds: configuration.rateWindowMilliseconds
        )
        self.pairingFailureLimiter = FailureRateLimiter(
            limit: configuration.pairingFailureLimit,
            windowMilliseconds: configuration.pairingFailureWindowMilliseconds,
            baseBackoffMilliseconds: configuration.pairingBackoffBaseMilliseconds,
            maximumBackoffMilliseconds: configuration.pairingBackoffMaximumMilliseconds
        )
    }

    public func registerAgentAdapter(_ adapter: any AgentAdapter) async {
        await sessionOrchestrator?.registerAdapter(adapter)
    }

    /// Starts a structured agent session on the companion (§29 Phase 6).
    public func startAgentSession(
        agent: AgentIdentifier,
        configuration: AgentLaunchConfiguration
    ) async throws -> SessionID {
        guard let sessionOrchestrator else {
            throw PairingError.protocolViolation("session orchestrator unavailable")
        }
        return try await sessionOrchestrator.startSession(agent: agent, configuration: configuration)
    }

    private func broadcastSessionEvent(_ event: AgentEvent) async {
        do {
            let payload = try event.toJSONValue()
            let cursor = event.cursor
            for connection in liveConnections.values {
                try await connection.send(type: .sessionEvent, payload: payload, cursor: cursor)
            }
        } catch {
            Log.logger(.session).error(
                "broadcast session event failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// §29 terminal streaming: forwards a PTY output chunk to every paired
    /// device, chunked to stay inside the §9 terminal frame budget.
    public func broadcastTerminalOutput(sessionID: SessionID, data: Data) async {
        guard !liveConnections.isEmpty, !data.isEmpty else { return }
        let chunkSize = 48 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let payload = TerminalStreamBridge.makeOutputFrame(
                sessionID: sessionID,
                data: data.subdata(in: offset..<end)
            )
            for connection in liveConnections.values {
                do {
                    try await connection.send(type: .terminalOutput, payload: payload)
                } catch {
                    Log.logger(.session).error(
                        "broadcast terminal output failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            offset = end
        }
    }

    /// §6 Home: pushes the current agent inventory to every paired device
    /// (called after connect, session start, and session end).
    public func pushAgentSnapshot() async {
        guard let provider = configuration.agentStateProvider else { return }
        let agents = await provider()
        let payload = AgentSnapshot(agents: agents).toJSONValue()
        for connection in liveConnections.values {
            do {
                try await connection.send(type: .agentSnapshot, payload: payload)
            } catch {
                Log.logger(.session).error(
                    "push agent snapshot failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Offers (QR window)

    /// Creates a fresh 120 s pairing offer for the QR window.
    @discardableResult
    public func makeOffer() async -> PairingOffer {
        await offerManager.createOffer(now: configuration.nowProvider())
    }

    public func cancelOffer() async {
        await offerManager.cancelOffer()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        sessionOrchestrator = AgentSessionOrchestrator(
            repository: repository,
            broadcast: { event in
                await self.broadcastSessionEvent(event)
            },
            notificationDispatch: configuration.notificationDispatch
        )
        let listener = try PeerListener(
            tlsIdentity: configuration.tlsIdentity,
            port: configuration.listenPort,
            serviceName: configuration.serviceName,
            signingPrivateKey: configuration.privateKey,
            counter: counter
        )
        self.listener = listener
        await listener.start()
        try await listener.waitForReady(timeoutMilliseconds: 5_000)
        boundPort = await listener.boundPort
        if let boundPort {
            await offerManager.update(endpoint: PeerEndpoint(host: configuration.advertisedHost, port: boundPort))
        }
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await connection in listener.connections {
                let taskID = UUID()
                let task = Task { await self.handle(connection: connection) }
                await self.registerConnectionTask(task, id: taskID)
            }
        }
    }

    private func registerConnectionTask(_ task: Task<Void, Never>, id: UUID) {
        connectionTasks[id] = task
    }

    public func stop() async {
        listenerTask?.cancel()
        await listener?.stop()
        for connection in liveConnections.values {
            await connection.close()
        }
        liveConnections.removeAll()
        connectionTasks.removeAll()
    }

    // MARK: - Handshake state machine (per connection)

    private func handle(connection: PeerConnection) async {
        // §13.4: key the limiter on the connection SOURCE (stable across
        // reconnects) — never a random UUID — and check it before any
        // frame/TLS-handshake work runs on this connection.
        let source = connection.remoteEndpointIdentifier
        guard await connectionLimiter.allow(source, now: configuration.nowProvider()) else {
            await connection.close()
            return
        }
        do {
            let first = try await nextFrame(from: connection, timeout: configuration.handshakeTimeoutMilliseconds)
            guard first.frame.type == .pairingHello else {
                throw PairingError.protocolViolation("expected pairing.hello, got \(first.frame.type.rawValue)")
            }
            let hello = try PairingHello(jsonValue: first.frame.payload)
            guard let clientKey = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.clientPublicKey),
                  verifyFrameSignature(first, with: clientKey) else {
                await recordPairingFailure(source, reason: "hello signature invalid")
                throw PairingError.signatureInvalid
            }

            let existingPeer = try await repository.device(id: hello.clientDeviceID)
            if let existing = existingPeer,
               existing.publicKey == hello.clientPublicKey,
               existing.revoked,
               hello.nonce == Data(count: 16) {
                try await rejectAndClose(connection, reason: .revoked)
                return
            }
            if let existing = existingPeer,
               existing.publicKey == hello.clientPublicKey,
               !existing.revoked {
                try await repository.updateDeviceLastSeen(existing.id, at: configuration.nowProvider())
                await connection.setPeerPublicKey(clientKey)
                try await connection.send(
                    type: .pairingComplete,
                    payload: PairingComplete(
                        protocolVersion: PairingQRPayload.version,
                        grantedCapabilities: PairingServerEngine.grantedCapabilities,
                        reconnectEndpoint: PeerEndpoint(
                            host: configuration.advertisedHost,
                            port: boundPort ?? configuration.listenPort
                        )
                    ).toJSONValue()
                )
                liveConnections[existing.id] = connection
                await serveSession(connection: connection, peerID: existing.id)
                return
            }

            // §13.4 pairing throttle: checked on the connection source
            // BEFORE nonce consumption and the attestation signature (the
            // expensive crypto), counting failures only.
            guard await pairingFailureLimiter.wouldAllow(source, now: configuration.nowProvider()) else {
                Log.logger(.security).warning(
                    "pairing rate limited for source \(source, privacy: .public)"
                )
                try await rejectAndClose(connection, reason: .rateLimited)
                return
            }

            switch await offerManager.consume(nonce: hello.nonce, now: configuration.nowProvider()) {
            case .accepted:
                break
            case .unknown:
                await recordPairingFailure(source, reason: "unknown nonce")
                try await rejectAndClose(connection, reason: .unknownNonce)
                return
            case .alreadyUsed:
                await recordPairingFailure(source, reason: "nonce replay")
                try await rejectAndClose(connection, reason: .nonceAlreadyUsed)
                return
            case .expired:
                await recordPairingFailure(source, reason: "nonce expired")
                try await rejectAndClose(connection, reason: .nonceExpired)
                return
            }
            guard hello.protocolVersion == PairingQRPayload.version else {
                await recordPairingFailure(source, reason: "protocol mismatch")
                try await rejectAndClose(connection, reason: .protocolMismatch)
                return
            }
            let activePeers = try await repository.listDevices().filter { !$0.revoked }
            guard activePeers.count < configuration.maxPairedClients else {
                try await rejectAndClose(connection, reason: .deviceLimitReached)
                return
            }

            // Accept: attestation binds the TLS key to the identity (§13.4).
            let verificationCode = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let attestation = try PairingAttestation.sign(
                serverDeviceID: configuration.identity.deviceID,
                tlsPublicKeyHash: configuration.tlsIdentity.publicKeyHash,
                nonce: hello.nonce,
                with: configuration.privateKey
            )
            try await connection.send(
                type: .pairingAccept,
                payload: PairingAccept(
                    serverDeviceID: configuration.identity.deviceID,
                    serverPublicKey: configuration.identity.publicKey.rawRepresentation,
                    serverDisplayName: configuration.displayName,
                    protocolVersion: PairingQRPayload.version,
                    verificationCode: verificationCode,
                    tlsPublicKeyHash: configuration.tlsIdentity.publicKeyHash,
                    attestation: attestation
                ).toJSONValue()
            )

            let phrase = VerificationPhrase.display(VerificationPhrase.words(
                serverPublicKey: configuration.identity.publicKey.rawRepresentation,
                clientPublicKey: hello.clientPublicKey,
                verificationCode: verificationCode
            ))
            async let localConfirmation = confirmationDelegate.confirmPairing(
                phrase: phrase,
                fingerprint: configuration.identity.shortFingerprint,
                peerDisplayName: hello.clientDisplayName
            )
            let confirmFrame = try await nextFrame(from: connection, timeout: configuration.confirmationTimeoutMilliseconds)
            guard confirmFrame.frame.type == .pairingConfirm else {
                await recordPairingFailure(source, reason: "expected pairing.confirm")
                throw PairingError.protocolViolation("expected pairing.confirm")
            }
            // §13.2/§9: the confirm frame is SECURITY-RELEVANT — acting on
            // it without verifying the client signature would let a
            // middlebox confirm on the client's behalf (hello is verified
            // above; confirm gets the same treatment).
            guard verifyFrameSignature(confirmFrame, with: clientKey) else {
                await recordPairingFailure(source, reason: "confirm signature invalid")
                throw PairingError.signatureInvalid
            }
            let remoteConfirm = try PairingConfirm(jsonValue: confirmFrame.frame.payload)
            guard remoteConfirm.deviceID == hello.clientDeviceID, remoteConfirm.confirmed else {
                try await rejectAndClose(connection, reason: .cancelled)
                return
            }
            guard await localConfirmation else {
                try await rejectAndClose(connection, reason: .cancelled)
                return
            }

            let peer = DeviceRecord(
                id: hello.clientDeviceID,
                displayName: hello.clientDisplayName,
                publicKey: hello.clientPublicKey,
                tlsPublicKeyHash: configuration.tlsIdentity.publicKeyHash,
                capabilities: PairingServerEngine.grantedCapabilities,
                pairedAt: configuration.nowProvider(),
                lastSeenAt: configuration.nowProvider()
            )
            // A revocation still blocks the zero-nonce silent reconnect path.
            // Reaching here proves the user scanned a fresh, single-use offer
            // and confirmed the phrase on both devices, so replace the stale
            // tombstone and allow an explicit re-pair.
            if existingPeer != nil {
                try await repository.deleteDevice(id: peer.id)
            }
            try await repository.insertDevice(peer)
            await connection.setPeerPublicKey(clientKey)
            try await connection.send(
                type: .pairingComplete,
                payload: PairingComplete(
                    protocolVersion: PairingQRPayload.version,
                    grantedCapabilities: PairingServerEngine.grantedCapabilities,
                    reconnectEndpoint: PeerEndpoint(
                        host: configuration.advertisedHost,
                        port: boundPort ?? configuration.listenPort
                    )
                ).toJSONValue()
            )
            // Full success clears the source's failure state (§13.4).
            await pairingFailureLimiter.recordSuccess(source)
            liveConnections[peer.id] = connection
            await serveSession(connection: connection, peerID: peer.id)
        } catch {
            await connection.close()
        }
    }

    /// §13.4: records a failed pairing attempt against the connection
    /// source (drives the 5/10-min limit and the exponential backoff).
    private func recordPairingFailure(_ source: String, reason: String) async {
        let backoff = await pairingFailureLimiter.recordFailure(source, now: configuration.nowProvider())
        Log.logger(.security).warning(
            "pairing failure from \(source, privacy: .public): \(reason, privacy: .public); backoff \(backoff, privacy: .public)ms"
        )
    }

    /// §13.4 Mac-side operator reset: clears the failure state of one
    /// source (e.g. "127.0.0.1") so a locked-out legitimate user can retry.
    public func resetPairingFailureLimit(forSource source: String) async {
        await pairingFailureLimiter.reset(source)
    }

    /// §13.4 Mac-side operator reset: clears ALL pairing failure state.
    public func resetAllPairingFailureLimits() async {
        await pairingFailureLimiter.resetAll()
    }

    private func rejectAndClose(_ connection: PeerConnection, reason: PairingRejectReason) async throws {
        try await connection.send(type: .pairingReject, payload: PairingReject(reason: reason).toJSONValue())
        await connection.close()
    }

    // MARK: - Session serving (resume + future session traffic)

    private func serveSession(
        connection: PeerConnection,
        peerID: DeviceID
    ) async {
        // §6 Home: greet a freshly (re)connected device with the current
        // agent inventory so its cards are live without polling.
        await pushAgentSnapshot()
        do {
            while let frame = try await connection.readFrame() {
                switch frame.frame.type {
                case .sessionResume:
                    let request = try SessionResumeRequest(jsonValue: frame.frame.payload)
                    try await replayEvents(for: request, rawPayload: frame.frame.payload, over: connection)
                case .sessionPrompt:
                    let request = try SessionPromptRequest(jsonValue: frame.frame.payload)
                    try await sessionOrchestrator?.sendPrompt(request.prompt, sessionID: request.sessionID)
                case .sessionStart:
                    let request = try SessionStartRequest(jsonValue: frame.frame.payload)
                    try await handleSessionStart(request)
                case .approvalResolve:
                    let request = try ApprovalResolveRequest(jsonValue: frame.frame.payload)
                    _ = try await sessionOrchestrator?.resolveApproval(
                        requestID: request.requestID,
                        decision: request.decision,
                        sessionID: request.sessionID,
                        usedSecureConfirmation: request.usedSecureConfirmation
                    )
                case .sessionInterrupt:
                    let request = try SessionInterruptRequest(jsonValue: frame.frame.payload)
                    try await sessionOrchestrator?.interrupt(sessionID: request.sessionID)
                case .devicePushToken:
                    let request = try DevicePushTokenRequest(jsonValue: frame.frame.payload)
                    // §20 IDOR fix: the push token is written for the
                    // AUTHENTICATED peer of this connection — never for a
                    // payload-asserted deviceID (which could re-point
                    // another device's notifications).
                    if request.deviceID != peerID {
                        Log.logger(.security).warning(
                            "device.pushToken payload deviceID mismatches authenticated peer; using the authenticated peer"
                        )
                    }
                    try await repository.updateDevicePushToken(peerID, token: request.destinationToken)
                case .terminalStart:
                    let request = try TerminalStartRequest(jsonValue: frame.frame.payload)
                    guard let handler = configuration.terminalStartHandler else {
                        throw PairingError.protocolViolation("terminal sessions unavailable on this companion")
                    }
                    let newSessionID = try await handler(request)
                    try await connection.send(
                        type: .terminalStarted,
                        payload: TerminalStartedResponse(
                            sessionID: newSessionID,
                            projectID: request.projectID,
                            agentID: request.agentID
                        ).toJSONValue()
                    )
                case .terminalInput:
                    let input = try TerminalStreamBridge.parseInput(frame.frame.payload)
                    try await configuration.terminalInputHandler?(input.sessionID, input.data)
                case .terminalResize:
                    let request = try TerminalResizeRequest(jsonValue: frame.frame.payload)
                    try await configuration.terminalResizeHandler?(request.sessionID, request.cols, request.rows)
                case .terminalAttach:
                    let request = try TerminalAttachRequest(jsonValue: frame.frame.payload)
                    if let scrollback = await configuration.terminalScrollbackProvider?(request.sessionID) {
                        for payload in TerminalStreamBridge.replayChunks(sessionID: request.sessionID, scrollback: scrollback) {
                            try await connection.send(type: .terminalOutput, payload: payload)
                        }
                    }
                case .projectList:
                    let projects = try await repository.listProjects().map(ProjectSummary.init(record:))
                    try await connection.send(
                        type: .projectListResponse,
                        payload: ProjectListResponse(projects: projects).toJSONValue()
                    )
                case .agentList:
                    let agents = await configuration.agentStateProvider?() ?? []
                    try await connection.send(
                        type: .agentListResponse,
                        payload: AgentSnapshot(agents: agents).toJSONValue()
                    )
                case .diffRequest:
                    let request = try DiffRequest(jsonValue: frame.frame.payload)
                    guard let provider = configuration.diffProvider else {
                        throw PairingError.protocolViolation("diff mirroring unavailable on this companion")
                    }
                    if let content = try await provider(request.sessionID, request.maxBytes) {
                        try await connection.send(type: .diffContent, payload: content.toJSONValue())
                    }
                case .heartbeat:
                    continue
                default:
                    // Phase 6+ owns session-event ingestion and approvals.
                    continue
                }
            }
        } catch {
            // Connection failed mid-stream; fall through to cleanup.
        }
        liveConnections[peerID] = nil
        await connection.close()
    }

    /// §29 Phase 6 `session.start`: routes through the same orchestrator
    /// start path the companion uses, with §12.4 project authorization,
    /// the concurrent-session cap, and §16/§20.2 containment checks (the
    /// working directory is the authorized project root — the contract
    /// carries no client-supplied path). Resulting `session.event`s are
    /// broadcast to every connected peer by the orchestrator, like the
    /// existing flows.
    private func handleSessionStart(_ request: SessionStartRequest) async throws {
        guard let orchestrator = sessionOrchestrator else {
            throw PairingError.protocolViolation("session orchestrator unavailable")
        }
        guard let project = try await repository.project(id: request.projectID) else {
            throw AgentSessionOrchestratorError.projectNotAuthorized(request.projectID)
        }
        _ = try await orchestrator.startSession(
            agent: request.agentID,
            configuration: AgentLaunchConfiguration(
                projectID: request.projectID,
                workingDirectory: project.canonicalPath,
                initialPrompt: request.prompt,
                model: request.model
            )
        )
        await pushAgentSnapshot()
    }

    /// §9 resume: replay events after the client's cursor from the §12.5
    /// store, each frame carrying its cursor.
    ///
    /// Pagination (backward-compatible): a request carrying an optional
    /// `pageSize` field opts into cursor-based paging — the server sends at
    /// most `pageSize` events and then a `session.event` frame with a
    /// transport `resumePage` notice (`hasMore` + the cursor to continue
    /// from). Requests WITHOUT `pageSize` get exactly the legacy behavior
    /// (≤500 events, no marker).
    private func replayEvents(
        for request: SessionResumeRequest,
        rawPayload: JSONValue,
        over connection: PeerConnection
    ) async throws {
        guard let cursor = request.lastCursor,
              let session = try await repository.session(id: cursor.sessionID) else {
            return
        }
        let requestedPageSize = try rawPayload.optionalIntField("pageSize")
        let pageSize = requestedPageSize.map { min(500, max(1, $0)) } ?? 500
        let events = try await repository.events(
            sessionID: cursor.sessionID,
            afterSequence: cursor.lastEventSequence,
            limit: Int(pageSize)
        )
        var lastSentSequence = cursor.lastEventSequence
        for record in events {
            let event = AgentEvent(
                id: record.id,
                sessionID: record.sessionID,
                agent: session.agent,
                sequence: record.sequence,
                timestamp: record.timestamp,
                confidence: record.confidence,
                payload: try AgentEventPayload(kind: record.kind, data: record.payload)
            )
            try await connection.send(
                type: .sessionEvent,
                payload: try event.toJSONValue(),
                cursor: EventCursor(sessionID: record.sessionID, lastEventSequence: record.sequence)
            )
            lastSentSequence = record.sequence
        }
        // Paged mode only: declare whether more history remains so the
        // client can continue with another session.resume at the cursor.
        if requestedPageSize != nil {
            let hasMore = events.count == Int(pageSize)
            let marker = AgentEvent(
                sessionID: session.id,
                agent: session.agent,
                sequence: 0, // synthetic transport marker — never persisted
                timestamp: configuration.nowProvider(),
                confidence: .native,
                payload: .transport(TransportNotice(
                    code: .resumePage,
                    message: hasMore ? "More history remains; resume again from the cursor." : "Resume complete.",
                    metadata: .object([
                        ("hasMore", .bool(hasMore)),
                        ("lastEventSequence", try JSONValue.u64(lastSentSequence))
                    ])
                ))
            )
            try await connection.send(
                type: .sessionEvent,
                payload: try marker.toJSONValue(),
                cursor: EventCursor(sessionID: session.id, lastEventSequence: lastSentSequence)
            )
        }
    }

    // MARK: - Revocation (§13.3)

    /// Revokes a peer: terminates its connection immediately and
    /// invalidates its credentials.
    public func revokePeer(_ deviceID: DeviceID) async throws {
        try await repository.setDeviceRevoked(deviceID, revoked: true)
        if let connection = liveConnections[deviceID] {
            await connection.close()
            liveConnections[deviceID] = nil
        }
    }

    public func pairedPeers() async throws -> [DeviceRecord] {
        try await repository.listDevices()
    }
}
#endif

// MARK: - Client engine

public actor PairingClientEngine {
    public struct Configuration: Sendable {
        public var identity: DeviceIdentity
        public var privateKey: Curve25519.Signing.PrivateKey
        public var displayName: String
        /// §13.3: up to 5 paired Macs per iOS device.
        public var maxPairedMacs: Int = 5
        public var handshakeTimeoutMilliseconds: UInt64 = 30_000
        public var nowProvider: @Sendable () -> Int64 = { Date.unixMillisecondsNow }

        public init(
            identity: DeviceIdentity,
            privateKey: Curve25519.Signing.PrivateKey,
            displayName: String
        ) {
            self.identity = identity
            self.privateKey = privateKey
            self.displayName = displayName
        }
    }

    public enum Outcome: Sendable, Equatable {
        case paired(DeviceID)
        case rejected(PairingRejectReason)
        case cancelledByUser
    }

    private let configuration: Configuration
    private let repository: any SessionRepository
    private let confirmationDelegate: any PairingConfirmationDelegate
    private let counter: MetricsCounter?

    public init(
        configuration: Configuration,
        repository: any SessionRepository,
        confirmationDelegate: any PairingConfirmationDelegate,
        counter: MetricsCounter? = nil
    ) {
        self.configuration = configuration
        self.repository = repository
        self.confirmationDelegate = confirmationDelegate
        self.counter = counter
    }

    /// Runs the full pairing flow against the scanned QR payload.
    /// Returns the live connection on success (session traffic continues
    /// on it) plus the outcome.
    public func pair(
        qrPayload: PairingQRPayload
    ) async throws -> (outcome: Outcome, connection: PeerConnection?) {
        // §13.3 client-side device limit.
        let existing = try await repository.listDevices().filter { !$0.revoked }
        if !existing.contains(where: { $0.id == qrPayload.deviceID }),
           existing.count >= configuration.maxPairedMacs {
            throw PairingError.deviceLimitReached
        }

        let capturedHash = LockedValue<String?>(nil)
        let parameters = TransportSecurity.clientParameters(pinnedPublicKeyHash: nil) { hash in
            capturedHash.set(hash)
        }
        let nwConnection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host(qrPayload.endpoint.host),
                port: NWEndpoint.Port(rawValue: qrPayload.endpoint.port) ?? 47_777
            ),
            using: parameters
        )
        let connection = PeerConnection(
            connection: nwConnection,
            localPrivateKey: configuration.privateKey,
            counter: counter
        )
        await connection.start()
        try await connection.waitForReady(timeoutMilliseconds: configuration.handshakeTimeoutMilliseconds)

        do {
            // 1. Hello (signed; carries our identity key + the QR nonce).
            try await connection.send(
                type: .pairingHello,
                payload: PairingHello(
                    nonce: qrPayload.nonce,
                    clientDeviceID: configuration.identity.deviceID,
                    clientPublicKey: configuration.identity.publicKey.rawRepresentation,
                    clientDisplayName: configuration.displayName,
                    protocolVersion: PairingQRPayload.version
                ).toJSONValue()
            )

            // 2. Accept or reject.
            let reply = try await nextFrame(from: connection, timeout: configuration.handshakeTimeoutMilliseconds)
            switch reply.frame.type {
            case .pairingReject:
                let reject = try PairingReject(jsonValue: reply.frame.payload)
                await connection.close()
                return (.rejected(reject.reason), nil)
            case .pairingAccept:
                break
            default:
                throw PairingError.protocolViolation("expected pairing.accept/reject")
            }
            let accept = try PairingAccept(jsonValue: reply.frame.payload)

            // 3. Endpoint binding + identity verification (§13.4).
            guard let serverKey = try? Curve25519.Signing.PublicKey(rawRepresentation: accept.serverPublicKey) else {
                throw PairingError.identityMismatch
            }
            guard DeviceIdentity.fingerprint(of: serverKey) == qrPayload.publicKeyFingerprint,
                  accept.serverDeviceID == qrPayload.deviceID else {
                throw PairingError.identityMismatch
            }
            guard capturedHash.get() == accept.tlsPublicKeyHash else {
                throw PairingError.endpointBindingMismatch
            }
            guard PairingAttestation.verify(
                accept.attestation,
                serverDeviceID: accept.serverDeviceID,
                tlsPublicKeyHash: accept.tlsPublicKeyHash,
                nonce: qrPayload.nonce,
                publicKey: serverKey
            ), verifyFrameSignature(reply, with: serverKey) else {
                throw PairingError.signatureInvalid
            }

            // 4. Phrase confirmation (§13.2).
            let phrase = VerificationPhrase.display(VerificationPhrase.words(
                serverPublicKey: accept.serverPublicKey,
                clientPublicKey: configuration.identity.publicKey.rawRepresentation,
                verificationCode: accept.verificationCode
            ))
            let fingerprint = String(DeviceIdentity.fingerprint(of: serverKey).prefix(16))
            let confirmed = await confirmationDelegate.confirmPairing(
                phrase: phrase,
                fingerprint: fingerprint,
                peerDisplayName: accept.serverDisplayName
            )
            try await connection.send(
                type: .pairingConfirm,
                payload: PairingConfirm(
                    deviceID: configuration.identity.deviceID,
                    confirmed: confirmed
                ).toJSONValue()
            )
            guard confirmed else {
                await connection.close()
                return (.cancelledByUser, nil)
            }

            // 5. Complete: pin the peer key, persist the peer.
            let completeFrame = try await nextFrame(from: connection, timeout: configuration.handshakeTimeoutMilliseconds)
            switch completeFrame.frame.type {
            case .pairingComplete:
                break
            case .pairingReject:
                let reject = try PairingReject(jsonValue: completeFrame.frame.payload)
                await connection.close()
                return (.rejected(reject.reason), nil)
            default:
                throw PairingError.protocolViolation("expected pairing.complete")
            }
            guard verifyFrameSignature(completeFrame, with: serverKey) else {
                throw PairingError.signatureInvalid
            }
            let complete = try PairingComplete(jsonValue: completeFrame.frame.payload)
            await connection.setPeerPublicKey(serverKey)
            let peer = DeviceRecord(
                id: accept.serverDeviceID,
                displayName: accept.serverDisplayName,
                publicKey: accept.serverPublicKey,
                tlsPublicKeyHash: accept.tlsPublicKeyHash,
                capabilities: complete.grantedCapabilities,
                pairedAt: configuration.nowProvider(),
                lastSeenAt: configuration.nowProvider(),
                lastKnownEndpoint: (complete.reconnectEndpoint ?? qrPayload.endpoint).description
            )
            if try await repository.device(id: peer.id) != nil {
                // Re-pair: refresh the record.
                try await repository.deleteDevice(id: peer.id)
            }
            try await repository.insertDevice(peer)
            return (.paired(accept.serverDeviceID), connection)
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Reconnects to a paired peer (pinned TLS hash; server shortcuts the
    /// QR flow for known devices).
    public func connectToPairedPeer(
        _ peer: DeviceRecord,
        endpoint: PeerEndpoint
    ) async throws -> PeerConnection {
        let parameters = TransportSecurity.clientParameters(pinnedPublicKeyHash: peer.tlsPublicKeyHash)
        let nwConnection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: endpoint.port) ?? 47_777
            ),
            using: parameters
        )
        let connection = PeerConnection(
            connection: nwConnection,
            localPrivateKey: configuration.privateKey,
            peerPublicKey: peer.publicKey.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) },
            counter: counter
        )
        await connection.start()
        try await connection.waitForReady(timeoutMilliseconds: configuration.handshakeTimeoutMilliseconds)
        try await connection.send(
            type: .pairingHello,
            payload: PairingHello(
                nonce: Data(count: 16), // unused on the reconnect path
                clientDeviceID: configuration.identity.deviceID,
                clientPublicKey: configuration.identity.publicKey.rawRepresentation,
                clientDisplayName: configuration.displayName,
                protocolVersion: PairingQRPayload.version
            ).toJSONValue()
        )
        let reply = try await nextFrame(from: connection, timeout: configuration.handshakeTimeoutMilliseconds)
        switch reply.frame.type {
        case .pairingComplete:
            guard let serverKey = peer.publicKey.flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
                  verifyFrameSignature(reply, with: serverKey) else {
                throw PairingError.signatureInvalid
            }
            let complete = try PairingComplete(jsonValue: reply.frame.payload)
            if let endpoint = complete.reconnectEndpoint,
               endpoint != peer.peerEndpoint {
                try await repository.updateDeviceEndpoint(peer.id, endpoint: endpoint.description)
            }
            return connection
        case .pairingReject:
            let reject = try PairingReject(jsonValue: reply.frame.payload)
            throw PairingError.rejectedByPeer(reject.reason)
        default:
            throw PairingError.protocolViolation("expected pairing.complete/reject on reconnect")
        }
    }
}

// MARK: - session.start payload (§29 Phase 6, ADR-0013 family)

/// Client → companion: start a structured agent session on an authorized
/// project. Contract (fixed; the iOS client builds against it):
/// `{projectID, agentID, prompt, model?}` — `prompt` decodes from the
/// nested §10.2 PromptInput object and, tolerantly, from a plain string.
/// The companion derives the working directory from the authorized
/// project record; clients never supply paths.
public struct SessionStartRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let projectID: ProjectID
    public let agentID: AgentIdentifier
    public let prompt: PromptInput
    public let model: String?

    public init(
        projectID: ProjectID,
        agentID: AgentIdentifier,
        prompt: PromptInput,
        model: String? = nil
    ) {
        self.projectID = projectID
        self.agentID = agentID
        self.prompt = prompt
        self.model = model
    }
}

extension SessionStartRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let projectID = "projectID"
        static let agentID = "agentID"
        static let prompt = "prompt"
        static let model = "model"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.projectID = try jsonValue.nestedField(Field.projectID, as: ProjectID.self)
        self.agentID = try jsonValue.nestedField(Field.agentID, as: AgentIdentifier.self)
        let promptField = try jsonValue.requiredField(Field.prompt)
        if let text = promptField.stringValue {
            self.prompt = PromptInput(text: text)
        } else {
            self.prompt = try PromptInput(jsonValue: promptField)
        }
        self.model = try jsonValue.optionalStringField(Field.model)
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.projectID, projectID.toJSONValue()),
            (Field.agentID, agentID.toJSONValue()),
            (Field.prompt, prompt.toJSONValue())
        ]
        if let model {
            pairs.append((Field.model, .string(model)))
        }
        return .object(pairs)
    }
}

// MARK: - Shared helpers

/// Verifies that `frame.sig` is a valid Ed25519 signature over the
/// canonical signing form of `frame` (§9).
func verifyFrameSignature(
    _ frame: SignedFrame,
    with key: Curve25519.Signing.PublicKey
) -> Bool {
    guard let bytes = try? frame.frame.signingJSONValue().canonicalBytes() else {
        return false
    }
    return key.isValidSignature(frame.signature, for: bytes)
}

/// Reads the next frame with a timeout.
func nextFrame(
    from connection: PeerConnection,
    timeout milliseconds: UInt64
) async throws -> SignedFrame {
    let frameTask = Task {
        guard let frame = try await connection.readFrame() else {
            throw PairingError.protocolViolation("connection closed mid-handshake")
        }
        return frame
    }
    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        frameTask.cancel()
    }
    do {
        let result = try await frameTask.value
        timeoutTask.cancel()
        return result
    } catch is CancellationError {
        throw PairingError.timeout
    } catch {
        timeoutTask.cancel()
        throw error
    }
}

/// Minimal Sendable box for a value captured by @Sendable closures
/// (TLS verify block). NSLock-based; no async needed.
final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
