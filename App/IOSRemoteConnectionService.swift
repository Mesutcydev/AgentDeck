//
//  IOSRemoteConnectionService.swift
//  App — AgentDeck
//
//  Keeps live PeerConnection sessions to paired Macs, mirrors session.event
//  frames into the local repository, and forwards approval.resolve frames.
//  Reconnects with exponential backoff (0.5 s → 30 s cap + jitter) and a
//  circuit breaker; the user retries manually once the circuit opens.
//

import CryptoKit
import Foundation
import Shared

actor IOSRemoteConnectionService {
    struct Status: Sendable, Equatable {
        var connectedDeviceIDs: Set<DeviceID> = []
        var lastError: String?
        /// Consecutive failed reconnect rounds (drives backoff).
        var consecutiveFailures = 0
        /// True after too many failures; reconnect stops until manual retry.
        var circuitOpen = false
        /// True when the transport was deliberately suspended (background).
        var suspended = false
    }

    /// Backoff policy: 0.5 s doubling to a 30 s cap with ≤25% jitter.
    private static let baseBackoffNanoseconds: UInt64 = 500_000_000
    private static let maxBackoffNanoseconds: UInt64 = 30_000_000_000
    private static let failuresBeforeCircuitOpen = 8

    private let repository: any SessionRepository
    private let mirror: SessionEventMirror
    private var connections: [DeviceID: PeerConnection] = [:]
    private var activeDeviceID: DeviceID?
    private var sessionOwners: [SessionID: DeviceID] = [:]
    private static let sessionOwnersDefaultsKey = "sessionHostOwners"
    private var readTasks: [DeviceID: Task<Void, Never>] = [:]
    private var status = Status()
    private var changeHandler: (@Sendable () async -> Void)?
    private var terminalOutputHandler: (@Sendable (SessionID, Data, Bool) -> Void)?
    private var reconnectContext: PairingClientEngine.Configuration?
    private var reconnectTask: Task<Void, Never>?
    private var isAttemptingReconnect = false
    private var hasReconnectablePeers = false
    private var resumeCursorOverrides: [SessionID: UInt64] = [:]
    private var stateSyncHandler: (@Sendable (StateSyncMessage) -> Void)?
    private var diffContentHandler: (@Sendable (JSONValue) -> Void)?
    private var terminalStartedHandler: (@Sendable (TerminalStartedResponse) -> Void)?
    private var attachmentWireHandler: (@Sendable (AttachmentWireResponse) async -> Void)?

    init(repository: any SessionRepository) {
        self.repository = repository
        self.mirror = SessionEventMirror(repository: repository)
        if let stored = UserDefaults.standard.dictionary(forKey: Self.sessionOwnersDefaultsKey) as? [String: String] {
            self.sessionOwners = Dictionary(uniqueKeysWithValues: stored.compactMap { session, device in
                guard let sessionID = SessionID(session), let deviceID = DeviceID(device) else { return nil }
                return (sessionID, deviceID)
            })
        }
    }

    func setChangeHandler(_ handler: (@Sendable () async -> Void)?) {
        changeHandler = handler
    }

    func setTerminalOutputHandler(_ handler: (@Sendable (SessionID, Data, Bool) -> Void)?) {
        terminalOutputHandler = handler
    }

    /// Receives `project.list.response` / `agent.list.response` /
    /// `agent.snapshot` payloads for the state-sync mirror.
    func setStateSyncHandler(_ handler: (@Sendable (StateSyncMessage) -> Void)?) {
        stateSyncHandler = handler
    }

    /// Receives `diff.content` payloads keyed by their sessionID field.
    func setDiffContentHandler(_ handler: (@Sendable (JSONValue) -> Void)?) {
        diffContentHandler = handler
    }

    /// Receives `attachment.init.response` / `attachment.ack` payloads for
    /// the transfer coordinator.
    func setAttachmentWireHandler(_ handler: (@Sendable (AttachmentWireResponse) async -> Void)?) {
        attachmentWireHandler = handler
    }

    /// Receives `terminal.started` responses (new shell PTY per project).
    func setTerminalStartedHandler(_ handler: (@Sendable (TerminalStartedResponse) -> Void)?) {
        terminalStartedHandler = handler
    }

    /// Cursors persisted before backgrounding; combined conservatively with
    /// repository state on resume (never ahead of what is stored locally).
    func setResumeCursorOverrides(_ overrides: [SessionID: UInt64]) {
        resumeCursorOverrides = overrides
    }

    func currentStatus() -> Status {
        status
    }

    func setActiveDeviceID(_ deviceID: DeviceID?) async {
        activeDeviceID = deviceID
        guard let deviceID, let connection = connections[deviceID] else { return }
        await requestStateSync(over: connection)
        await notifyChange()
    }

    func adopt(
        connection: PeerConnection,
        deviceID: DeviceID,
        configuration: PairingClientEngine.Configuration
    ) async {
        await stop(deviceID: deviceID)
        // Adoption is also the authoritative reconnect seed. Pairing may
        // finish before the app-start reconnect task has initialized this
        // context, especially immediately after onboarding.
        reconnectContext = configuration
        hasReconnectablePeers = true
        status.suspended = false
        status.circuitOpen = false
        status.consecutiveFailures = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        connections[deviceID] = connection
        status.connectedDeviceIDs.insert(deviceID)
        status.lastError = nil
        readTasks[deviceID] = Task {
            await self.serve(connection: connection, deviceID: deviceID, configuration: configuration)
        }
        await resumeSessions(over: connection, deviceID: deviceID)
        await requestStateSync(over: connection)
        await notifyChange()
    }

    func reconnectAll(
        identity: DeviceIdentity,
        privateKey: Curve25519.Signing.PrivateKey,
        displayName: String
    ) async {
        reconnectContext = PairingClientEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            displayName: displayName
        )
        status.suspended = false
        status.circuitOpen = false
        status.consecutiveFailures = 0
        await attemptReconnect()
    }

    /// Manual retry after the circuit breaker opened (user action).
    func retryManually() async {
        status.circuitOpen = false
        status.consecutiveFailures = 0
        status.suspended = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await attemptReconnect()
    }

    /// Gracefully suspends transport (app backgrounded): stops the reconnect
    /// loop and closes connections without recording failures.
    func suspendTransport() async {
        status.suspended = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await stopAll()
        await notifyChange()
    }

    /// One reconnect round over all non-revoked paired peers.
    private func attemptReconnect() async {
        guard !status.suspended, !status.circuitOpen, !isAttemptingReconnect,
              let configuration = reconnectContext else { return }
        isAttemptingReconnect = true
        defer { isAttemptingReconnect = false }
        do {
            let peers = try await repository.listDevices().filter { !$0.revoked }
            hasReconnectablePeers = peers.contains { $0.peerEndpoint != nil }
            var attempted = 0
            for peer in peers {
                guard let endpoint = peer.peerEndpoint else { continue }
                if connections[peer.id] != nil { continue }
                attempted += 1
                do {
                    // Reconnect path: the delegate auto-approves ONLY when the
                    // fingerprint the engine derived matches the key pinned at
                    // pairing; any mismatch fails closed.
                    let expectedFingerprint = peer.publicKey
                        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
                        .map { String(DeviceIdentity.fingerprint(of: $0).prefix(16)) }
                    let engine = PairingClientEngine(
                        configuration: configuration,
                        repository: repository,
                        confirmationDelegate: PinnedFingerprintPairingDelegate(
                            expectedFingerprint: expectedFingerprint
                        )
                    )
                    let connection = try await engine.connectToPairedPeer(peer, endpoint: endpoint)
                    await adopt(connection: connection, deviceID: peer.id, configuration: configuration)
                } catch {
                    status.lastError = "reconnect \(peer.displayName): \(error.localizedDescription)"
                }
            }
            if attempted == 0 || !status.connectedDeviceIDs.isEmpty {
                // Nothing to connect to, or at least one peer is live.
                status.consecutiveFailures = 0
                if !status.connectedDeviceIDs.isEmpty {
                    status.lastError = nil
                }
            } else {
                registerReconnectFailure()
            }
            await notifyChange()
        } catch {
            status.lastError = error.localizedDescription
            registerReconnectFailure()
            await notifyChange()
        }
        scheduleReconnectIfNeeded()
    }

    private func registerReconnectFailure() {
        status.consecutiveFailures += 1
        if status.consecutiveFailures >= Self.failuresBeforeCircuitOpen {
            status.circuitOpen = true
        }
    }

    /// Schedules the next backoff-delayed reconnect round, unless the
    /// circuit is open or the transport is suspended.
    private func scheduleReconnectIfNeeded() {
        guard !status.suspended, !status.circuitOpen, reconnectContext != nil,
              reconnectTask == nil, status.connectedDeviceIDs.isEmpty,
              hasReconnectablePeers else { return }
        let shift = min(max(status.consecutiveFailures - 1, 0), 6)
        let capped = min(
            Self.maxBackoffNanoseconds,
            Self.baseBackoffNanoseconds &<< UInt64(shift)
        )
        let jitter = UInt64.random(in: 0...(capped / 4))
        let delay = capped + jitter
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            await self.clearReconnectTask()
            await self.attemptReconnect()
        }
    }

    private func clearReconnectTask() {
        reconnectTask = nil
    }

    /// A live connection dropped: close it out and reconnect through the
    /// backoff policy (never in a tight loop).
    private func handleConnectionDropped() {
        // A peer was connected moments ago, so it is worth reconnecting to.
        hasReconnectablePeers = true
        scheduleReconnectIfNeeded()
    }

    func sendApprovalResolve(
        requestID: ApprovalRequestID,
        sessionID: SessionID,
        decision: ApprovalDecision,
        usedSecureConfirmation: Bool
    ) async throws {
        let request = ApprovalResolveRequest(
            requestID: requestID,
            sessionID: sessionID,
            decision: decision,
            usedSecureConfirmation: usedSecureConfirmation
        )
        try await send(type: .approvalResolve, payload: request.toJSONValue(), sessionID: sessionID)
    }

    /// §29 Phase 6 client prompt to an active session (`session.prompt`).
    func sendPrompt(sessionID: SessionID, text: String) async throws {
        let request = SessionPromptRequest(
            sessionID: sessionID,
            prompt: PromptInput(text: text)
        )
        try await send(type: .sessionPrompt, payload: request.toJSONValue(), sessionID: sessionID)
    }

    /// Interrupt a running session (`session.interrupt`).
    func sendInterrupt(sessionID: SessionID) async throws {
        let request = SessionInterruptRequest(sessionID: sessionID)
        try await send(type: .sessionInterrupt, payload: request.toJSONValue(), sessionID: sessionID)
    }

    /// PTY keystrokes/paste for a session (`terminal.input`, base64 data).
    func sendTerminalInput(sessionID: SessionID, data: Data) async throws {
        let payload = TerminalInputPayload(sessionID: sessionID, data: data)
        try await send(type: .terminalInput, payload: payload.toJSONValue(), sessionID: sessionID)
    }

    /// §29: launch a login-shell PTY inside an authorized project
    /// (`terminal.start`); the companion answers with `terminal.started`.
    func sendTerminalStart(projectID: ProjectID, agentID: AgentIdentifier? = nil, cols: Int, rows: Int) async throws {
        let request = TerminalStartRequest(projectID: projectID, agentID: agentID, cols: cols, rows: rows)
        try await send(type: .terminalStart, payload: request.toJSONValue())
    }

    /// Attach to a live PTY session (`terminal.attach`); the companion
    /// replays its scrollback as isReplay `terminal.output` chunks.
    func sendTerminalAttach(sessionID: SessionID) async throws {
        let request = TerminalAttachRequest(sessionID: sessionID)
        try await send(type: .terminalAttach, payload: request.toJSONValue(), sessionID: sessionID)
    }

    /// PTY window resize (`terminal.resize`, TIOCSWINSZ on the Mac).
    func sendTerminalResize(sessionID: SessionID, cols: Int, rows: Int) async throws {
        let request = TerminalResizeRequest(sessionID: sessionID, cols: cols, rows: rows)
        try await send(type: .terminalResize, payload: request.toJSONValue(), sessionID: sessionID)
    }

    /// Starts a session in an authorized project (`session.start`,
    /// payload `{projectID, agentID, prompt, model?}` per the contract).
    /// The raw-value frame-type lookup keeps this compiling even if the
    /// Shared case is momentarily absent during concurrent contract work.
    func sendSessionStart(
        projectID: ProjectID,
        agentID: AgentIdentifier,
        prompt: String,
        model: String?
    ) async throws {
        guard let frameType = FrameType(rawValue: "session.start") else {
            throw IOSRemoteConnectionError.unsupportedFrame("session.start")
        }
        let request = SessionStartRequest(
            projectID: projectID,
            agentID: agentID,
            prompt: PromptInput(text: prompt),
            model: model?.isEmpty == false ? model : nil
        )
        try await send(type: frameType, payload: request.toJSONValue())
    }

    /// Requests the working-tree diff for a session (`diff.request`,
    /// payload `{sessionID, maxBytes?}`). `maxBytes` keeps the response
    /// inside the 1 MiB frame cap (diff text is escaped, not base64).
    func sendDiffRequest(sessionID: SessionID, maxBytes: Int64?) async throws {
        guard let frameType = FrameType(rawValue: "diff.request") else {
            throw IOSRemoteConnectionError.unsupportedFrame("diff.request")
        }
        var pairs: [(String, JSONValue)] = [
            ("payloadV", .int(1)),
            ("sessionID", .string(sessionID.wireString))
        ]
        if let maxBytes {
            pairs.append(("maxBytes", .int(maxBytes)))
        }
        try await send(type: frameType, payload: .object(pairs), sessionID: sessionID)
    }

    /// `attachment.init` — opens a transfer for one composer attachment.
    func sendAttachmentInit(
        sessionID: SessionID,
        name: String,
        mimeType: String,
        totalBytes: Int64,
        sha256: String
    ) async throws {
        guard let frameType = FrameType(rawValue: "attachment.init") else {
            throw IOSRemoteConnectionError.unsupportedFrame("attachment.init")
        }
        try await send(type: frameType, payload: .object([
            ("payloadV", .int(1)),
            ("sessionID", .string(sessionID.wireString)),
            ("name", .string(name)),
            ("mimeType", .string(mimeType)),
            ("totalBytes", .int(totalBytes)),
            ("sha256", .string(sha256))
        ]))
    }

    /// `attachment.chunk` — one base64 chunk of an open transfer.
    func sendAttachmentChunk(transferID: String, index: Int64, data: Data, sha256: String) async throws {
        guard let frameType = FrameType(rawValue: "attachment.chunk") else {
            throw IOSRemoteConnectionError.unsupportedFrame("attachment.chunk")
        }
        try await send(type: frameType, payload: .object([
            ("payloadV", .int(1)),
            ("transferID", .string(transferID)),
            ("index", .int(index)),
            ("data", .string(data.base64EncodedString())),
            ("sha256", .string(sha256))
        ]))
    }

    /// `attachment.finalize` — closes a transfer; the peer answers with
    /// `attachment.ack`.
    func sendAttachmentFinalize(transferID: String) async throws {
        guard let frameType = FrameType(rawValue: "attachment.finalize") else {
            throw IOSRemoteConnectionError.unsupportedFrame("attachment.finalize")
        }
        try await send(type: frameType, payload: .object([
            ("payloadV", .int(1)),
            ("transferID", .string(transferID))
        ]))
    }

    private func send(type: FrameType, payload: JSONValue, sessionID: SessionID? = nil) async throws {
        let targetID = sessionID.flatMap { sessionOwners[$0] } ?? activeDeviceID
        // Never route through an arbitrary paired Mac. A selected Mac can be
        // offline while another peer remains connected; falling back made the
        // Home screen look live and then launched work on the wrong endpoint.
        guard let targetID, let connection = connections[targetID] else {
            throw IOSRemoteConnectionError.notConnected
        }
        try await connection.send(type: type, payload: payload)
    }

    func stop(deviceID: DeviceID) async {
        readTasks[deviceID]?.cancel()
        readTasks[deviceID] = nil
        if let connection = connections.removeValue(forKey: deviceID) {
            await connection.close()
        }
        status.connectedDeviceIDs.remove(deviceID)
    }

    func stopAll() async {
        for deviceID in Array(connections.keys) {
            await stop(deviceID: deviceID)
        }
    }

    private func serve(
        connection: PeerConnection,
        deviceID: DeviceID,
        configuration: PairingClientEngine.Configuration
    ) async {
        do {
            while let frame = try await connection.readFrame() {
                switch frame.frame.type {
                case .sessionEvent:
                    let event = try AgentEvent(jsonValue: frame.frame.payload)
                    assignOwner(deviceID, to: event.sessionID)
                    try await mirror.mirror(event)
                    try await repository.updateDeviceLastSeen(deviceID, at: Date.unixMillisecondsNow)
                    await notifyChange()
                case .terminalOutput:
                    let output = try TerminalOutputPayload(jsonValue: frame.frame.payload)
                    assignOwner(deviceID, to: output.sessionID)
                    terminalOutputHandler?(output.sessionID, output.data, output.isReplay)
                case .heartbeat:
                    continue
                default:
                    // State-sync / diff / attachment frames (contract landing
                    // concurrently): dispatch on the raw type so newly added
                    // Shared cases keep flowing here.
                    switch frame.frame.type.rawValue {
                    case "project.list.response":
                        guard deviceID == activeDeviceID else { continue }
                        stateSyncHandler?(.projectList(frame.frame.payload))
                        await notifyChange()
                    case "agent.list.response":
                        guard deviceID == activeDeviceID else { continue }
                        stateSyncHandler?(.agentList(frame.frame.payload))
                        await notifyChange()
                    case "agent.snapshot":
                        guard deviceID == activeDeviceID else { continue }
                        stateSyncHandler?(.agentSnapshot(frame.frame.payload))
                        await notifyChange()
                    case "diff.content":
                        diffContentHandler?(frame.frame.payload)
                    case "terminal.started":
                        if let response = try? TerminalStartedResponse(jsonValue: frame.frame.payload) {
                            assignOwner(deviceID, to: response.sessionID)
                            terminalStartedHandler?(response)
                        }
                    case "attachment.init.response":
                        await attachmentWireHandler?(.initResponse(frame.frame.payload))
                    case "attachment.ack":
                        await attachmentWireHandler?(.ack(frame.frame.payload))
                    default:
                        continue
                    }
                }
            }
        } catch {
            status.lastError = error.localizedDescription
        }
        // A superseded serve loop (its connection was replaced by a fresh
        // adopt) must not tear down or schedule anything for the new one.
        guard connections[deviceID] === connection else { return }
        await stop(deviceID: deviceID)
        await notifyChange()
        guard !status.suspended else { return }
        reconnectContext = configuration
        handleConnectionDropped()
    }

    /// Asks the companion for fresh project/agent state on (re)connect.
    /// Best-effort: if the Shared frame types have not landed yet, the
    /// requests are skipped and the UI keeps its honest "not synced" state.
    private func requestStateSync(over connection: PeerConnection) async {
        for rawType in ["project.list", "agent.list"] {
            guard let frameType = FrameType(rawValue: rawType) else { continue }
            try? await connection.send(
                type: frameType,
                payload: .object([("payloadV", .int(1))])
            )
        }
    }

    private func resumeSessions(over connection: PeerConnection, deviceID: DeviceID) async {
        do {
            let sessions = try await repository.listSessions()
            for session in sessions where !session.state.isTerminal {
                if let owner = sessionOwners[session.id], owner != deviceID { continue }
                // Highest persisted sequence: resume replays only what the
                // local store lacks; the mirror dedupes by event ID anyway.
                let storedLatest = try await repository.events(
                    sessionID: session.id,
                    afterSequence: nil,
                    limit: 500
                ).last?.sequence
                // Never claim a cursor ahead of what is durably stored; the
                // override only narrows replay when the store was reset.
                let sequence: UInt64?
                switch (storedLatest, resumeCursorOverrides[session.id]) {
                case let (stored?, override?):
                    sequence = min(stored, override)
                case let (stored?, nil):
                    sequence = stored
                default:
                    sequence = nil
                }
                let cursor = sequence.map {
                    EventCursor(sessionID: session.id, lastEventSequence: $0)
                }
                try await connection.send(
                    type: .sessionResume,
                    payload: SessionResumeRequest(lastCursor: cursor).toJSONValue()
                )
            }
        } catch {
            status.lastError = "resume failed: \(error.localizedDescription)"
        }
    }

    private func notifyChange() async {
        if let changeHandler {
            await changeHandler()
        }
    }

    private func assignOwner(_ deviceID: DeviceID, to sessionID: SessionID) {
        guard sessionOwners[sessionID] != deviceID else { return }
        sessionOwners[sessionID] = deviceID
        let encoded = Dictionary(uniqueKeysWithValues: sessionOwners.map {
            ($0.key.wireString, $0.value.wireString)
        })
        UserDefaults.standard.set(encoded, forKey: Self.sessionOwnersDefaultsKey)
    }
}

enum IOSRemoteConnectionError: Error, Equatable {
    case notConnected
    /// The Shared wire contract has not landed this frame type yet.
    case unsupportedFrame(String)
    /// `terminal.start` was sent but no `terminal.started` arrived in time.
    case terminalStartTimedOut
}

/// Inbound attachment-contract frames routed to the transfer coordinator.
enum AttachmentWireResponse: Sendable {
    case initResponse(JSONValue)
    case ack(JSONValue)
}

extension IOSRemoteConnectionService: AttachmentFrameSending {}

/// Reconnect-path confirmation: auto-approve ONLY when the fingerprint the
/// pairing engine derived from the live peer matches the fingerprint of the
/// key pinned at pairing time. Any change (or a missing pinned key) fails
/// closed and requires explicit re-pairing with user confirmation.
private struct PinnedFingerprintPairingDelegate: PairingConfirmationDelegate {
    let expectedFingerprint: String?

    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        guard let expectedFingerprint, !expectedFingerprint.isEmpty else { return false }
        return fingerprint == expectedFingerprint
    }
}
