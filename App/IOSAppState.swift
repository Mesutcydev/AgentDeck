//
//  IOSAppState.swift
//  App — AgentDeck
//
//  §13 iOS app state: device list, pairing engine, and identity storage.
//  Observable for SwiftUI; all async engine work stays off the main actor.
//

import CryptoKit
import Foundation
import Observation
import Shared
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Per-domain error state (replaces the single stringly pairing error).
enum AppErrorDomain: String, Sendable, CaseIterable {
    case pairing
    case connection
    case session
    case approval

    /// User-facing section title for the domain.
    var title: String {
        switch self {
        case .pairing: "Pairing"
        case .connection: "Connection"
        case .session: "Session"
        case .approval: "Approval"
        }
    }
}

/// A §13.2 pairing confirmation presented to the user. The human compares
/// the verification phrase and fingerprint with the Mac, then confirms or
/// rejects; the pairing engine awaits that choice.
struct PairingConfirmationRequest: Identifiable {
    let id = UUID()
    let phrase: String
    let fingerprint: String
    let peerDisplayName: String
    let endpoint: String?
}

/// App-side scene phase (keeps SwiftUI out of the state type).
enum AppScenePhase: Sendable {
    case active
    case inactive
    case background
}

/// Routes handled by `agentdeck://` deep links (widget + notifications).
enum AppDeepLink: Equatable, Sendable {
    case home
    case approvals
    case session(SessionID)
    case macs
}

/// Persists the last acknowledged per-session event cursor across
/// backgrounding so resume can pick up exactly where the app left off.
enum SessionCursorStore {
    private static let key = "agentdeck.sessionCursors.v1"

    static func load() -> [SessionID: UInt64] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var result: [SessionID: UInt64] = [:]
        for (sessionText, value) in raw {
            guard let sessionID = SessionID(sessionText) else { continue }
            if let number = value as? NSNumber {
                result[sessionID] = number.uint64Value
            } else if let text = value as? String, let sequence = UInt64(text) {
                result[sessionID] = sequence
            }
        }
        return result
    }

    static func save(_ cursors: [SessionID: UInt64]) {
        var raw: [String: String] = [:]
        for (sessionID, sequence) in cursors {
            raw[sessionID.wireString] = String(sequence)
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

/// §13.1 device identity stored in the iOS Keychain via `KeychainIdentityStore`.
@MainActor @Observable
final class IOSAppState {
    struct DebugEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String
    }

    private(set) var identity: DeviceIdentity?
    private(set) var privateKey: Curve25519.Signing.PrivateKey?
    private(set) var pairedDevices: [DeviceRecord] = []
    private(set) var connectedDeviceIDs: Set<DeviceID> = []
    private(set) var activeHostID: DeviceID?
    private(set) var sessions: [SessionRecord] = []
    private(set) var projects: [ProjectRecord] = []
    private(set) var pendingApprovalRecords: [ApprovalRecord] = []
    private(set) var approvalRules: [ApprovalRule] = []
    private(set) var approvalAuditEntries: [ApprovalAuditEntry] = []
    private(set) var pendingNotificationDeepLink: NotificationDeepLink?
    private(set) var remoteConnectionStatus: String = "Disconnected"
    private(set) var connectionCircuitOpen = false
    private(set) var isStoreDegraded = false
    private(set) var debugEntries: [DebugEntry] = []
    let subscription = SubscriptionManager()
    var paywallPresented = false
    private(set) var freeLaunchCount = UserDefaults.standard.integer(forKey: "freeAgentLaunchCount")
    static let freeLaunchLimit = 3
    /// Bumped whenever mirrored session/event state changes; views reload.
    private(set) var eventRevision = 0
    private(set) var pendingPairingConfirmation: PairingConfirmationRequest?
    private(set) var deepLinkSession: SessionID?
    /// Monotonic token so repeated deep links to the same target re-fire.
    private(set) var deepLinkNonce = 0
    private(set) var requestedTab: AppTab?
    /// Latest synced agent snapshot (agent.list.response / agent.snapshot);
    /// empty until the first sync lands — UI shows an honest empty state.
    private(set) var syncedAgents: [SyncedAgent] = []
    /// Opaque companion git-state strings keyed by project (ProjectRecord
    /// has no column for them; kept in memory only).
    private(set) var projectGitStates: [ProjectID: String] = [:]
    /// Latest `diff.content` per session (fetch-on-demand, not persisted).
    private(set) var diffContents: [SessionID: SessionDiffContent] = [:]
    /// Per-session diff request errors (kept out of the shared .session
    /// error domain so prompt errors never masquerade as diff errors).
    private(set) var diffErrors: [SessionID: String] = [:]
    /// Composer attachment uploads by local upload ID.
    private(set) var attachmentUploads: [UUID: AttachmentUpload] = [:]
    private var pendingPushToken: PushDestinationToken?
    private var pairingConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var activePairingEndpoint: String?

    private var errors: [AppErrorDomain: String] = [:]
    private let repository: any SessionRepository
    private let identityStore: KeychainIdentityStore
    private let policyEngine: ApprovalPolicyEngine
    private let authenticator: any DeviceAuthenticating
    private let remoteConnections: IOSRemoteConnectionService
    private let stateSyncMirror: StateSyncMirror
    private let syncedAgentStore = SyncedAgentStore()
    private let attachmentCoordinator: AttachmentTransferCoordinator
    private var terminalModels: [SessionID: TerminalSessionModel] = [:]
    private var activeProjectIDs: Set<ProjectID> = []
    private static let activeHostDefaultsKey = "activeHostDeviceID"

    init(
        repository: any SessionRepository,
        identityStore: KeychainIdentityStore,
        authenticator: any DeviceAuthenticating = LocalDeviceAuthenticator()
    ) {
        self.repository = repository
        self.identityStore = identityStore
        self.policyEngine = ApprovalPolicyEngine(repository: repository)
        self.authenticator = authenticator
        self.remoteConnections = IOSRemoteConnectionService(repository: repository)
        self.stateSyncMirror = StateSyncMirror(repository: repository)
        self.attachmentCoordinator = AttachmentTransferCoordinator(sender: remoteConnections)
        self.syncedAgents = syncedAgentStore.load()
        if let saved = UserDefaults.standard.string(forKey: Self.activeHostDefaultsKey) {
            self.activeHostID = DeviceID(saved)
        }
    }

    // MARK: - Errors (typed per domain)

    func error(for domain: AppErrorDomain) -> String? {
        errors[domain]
    }

    func setError(_ message: String?, domain: AppErrorDomain) {
        errors[domain] = message
        if let message { recordDebug(domain.rawValue, "ERROR · \(message)") }
    }

    func clearErrors() {
        errors.removeAll()
    }

    func recordDebug(_ category: String, _ message: String) {
        debugEntries.append(DebugEntry(timestamp: Date(), category: category.uppercased(), message: message))
        if debugEntries.count > 250 {
            debugEntries.removeFirst(debugEntries.count - 250)
        }
    }

    func clearDebugEntries() {
        debugEntries.removeAll(keepingCapacity: true)
        recordDebug("debug", "Log cleared")
    }

    // MARK: - Tabs / deep links

    enum AppTab: Int, Sendable {
        case home = 0
        case sessions = 1
        case approvals = 2
        case macs = 3
        case settings = 4
    }

    static func parseDeepLink(_ url: URL) -> AppDeepLink? {
        guard url.scheme == "agentdeck" else { return nil }
        switch url.host {
        case "home":
            return .home
        case "approvals":
            return .approvals
        case "macs":
            return .macs
        case "session":
            guard let idText = url.pathComponents.dropFirst().first,
                  let sessionID = SessionID(idText) else { return nil }
            return .session(sessionID)
        default:
            return nil
        }
    }

    func handleDeepLink(_ link: AppDeepLink) {
        deepLinkNonce += 1
        switch link {
        case .home:
            requestedTab = .home
        case .approvals:
            requestedTab = .approvals
        case .macs:
            requestedTab = .macs
        case .session(let sessionID):
            requestedTab = .sessions
            deepLinkSession = sessionID
        }
    }

    func consumeRequestedTab() -> AppTab? {
        defer { requestedTab = nil }
        return requestedTab
    }

    func consumeDeepLinkSession() -> SessionID? {
        defer { deepLinkSession = nil }
        return deepLinkSession
    }

    // MARK: - Connection lifecycle

    func startRemoteConnections() async {
        await subscription.start()
        await remoteConnections.setChangeHandler { [weak self] in
            await self?.refreshFromRemoteConnection()
        }
        await remoteConnections.setTerminalOutputHandler { [weak self] sessionID, data, isReplay in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let model = self.terminalModel(for: sessionID)
                if isReplay {
                    model.replayScrollback(data)
                } else {
                    model.feed(data)
                }
            }
        }
        await remoteConnections.setStateSyncHandler { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.applyStateSync(message)
            }
        }
        await remoteConnections.setDiffContentHandler { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.applyDiffContent(payload)
            }
        }
        await remoteConnections.setTerminalStartedHandler { [weak self] response in
            Task { @MainActor [weak self] in
                await self?.applyTerminalStarted(response)
            }
        }
        await remoteConnections.setAttachmentWireHandler { [weak self] response in
            guard let self else { return }
            await self.routeAttachmentResponse(response)
        }
        guard let identity, let privateKey else { return }
        await remoteConnections.reconnectAll(
            identity: identity,
            privateKey: privateKey,
            displayName: "iPhone"
        )
        await remoteConnections.setActiveDeviceID(activeHostID)
        await refreshFromRemoteConnection()
    }

    /// User-initiated retry after the reconnect circuit breaker opened.
    func retryConnections() async {
        setError(nil, domain: .connection)
        await remoteConnections.retryManually()
        await refreshFromRemoteConnection()
    }

    func handleScenePhase(_ phase: AppScenePhase) async {
        switch phase {
        case .background:
            await persistResumeCursors()
            await remoteConnections.suspendTransport()
            remoteConnectionStatus = "Suspended (backgrounded)"
        case .active:
            await remoteConnections.setResumeCursorOverrides(SessionCursorStore.load())
            await startRemoteConnections()
        case .inactive:
            break
        }
    }

    /// Records the highest persisted event sequence per live session so a
    /// later `session.resume` continues from the acknowledged position.
    private func persistResumeCursors() async {
        var cursors = SessionCursorStore.load()
        for session in sessions where !session.state.isTerminal {
            if let latest = try? await repository.events(
                sessionID: session.id,
                afterSequence: nil,
                limit: 500
            ).last?.sequence {
                cursors[session.id] = latest
            }
        }
        SessionCursorStore.save(cursors)
    }

    private func refreshFromRemoteConnection() async {
        let status = await remoteConnections.currentStatus()
        connectedDeviceIDs = status.connectedDeviceIDs
        connectionCircuitOpen = status.circuitOpen
        if !status.connectedDeviceIDs.isEmpty {
            let transport = activeHostTransportLabel
            remoteConnectionStatus = "\(transport) · \(status.connectedDeviceIDs.count) Mac\(status.connectedDeviceIDs.count == 1 ? "" : "s")"
            recordDebug("connection", remoteConnectionStatus)
            setError(nil, domain: .connection)
        } else if status.circuitOpen {
            remoteConnectionStatus = "Connection paused — reconnect manually"
            setError(
                status.lastError.map { "Reconnect failed repeatedly. Last error: \($0)" }
                    ?? "Reconnect failed repeatedly.",
                domain: .connection
            )
        } else {
            remoteConnectionStatus = status.lastError.map { "Disconnected — \($0)" } ?? "Disconnected"
            if let lastError = status.lastError {
                setError(lastError, domain: .connection)
            } else {
                setError(nil, domain: .connection)
            }
        }
        await refreshSessions()
        await refreshApprovalState()
        publishWidgetSummary()
    }

    private func publishWidgetSummary() {
        let connectedName = pairedDevices.first(where: { device in
            !device.revoked
        })?.displayName
        WidgetSummaryPublisher.publish(
            connectedMacName: connectedName,
            sessions: sessions,
            pendingApprovalCount: pendingApprovalRecords.count,
            connectionStatus: remoteConnectionStatus
        )
    }

    /// Loads or creates the device's Ed25519 identity.
    func loadIdentity() async {
        do {
            let identity = try identityStore.loadOrCreate()
            let privateKey = try identityStore.privateKey()
            self.identity = identity
            self.privateKey = privateKey
        } catch {
            setError("Identity load failed: \(error.localizedDescription)", domain: .pairing)
        }
    }

    /// Refreshes the list of paired Macs from the repository.
    func refreshDevices() async {
        do {
            pairedDevices = try await repository.listDevices()
            let available = pairedDevices.filter { !$0.revoked }
            if activeHostID == nil || !available.contains(where: { $0.id == activeHostID }) {
                activeHostID = available.first?.id
                if let activeHostID {
                    UserDefaults.standard.set(activeHostID.wireString, forKey: Self.activeHostDefaultsKey)
                    await remoteConnections.setActiveDeviceID(activeHostID)
                }
            }
            setError(nil, domain: .pairing)
            publishWidgetSummary()
        } catch {
            setError("Device list failed: \(error.localizedDescription)", domain: .pairing)
        }
    }

    func refreshSessions() async {
        do {
            sessions = try await repository.listSessions().sorted { $0.updatedAt > $1.updatedAt }
            eventRevision += 1
        } catch {
            setError("Session list failed: \(error.localizedDescription)", domain: .session)
        }
    }

    func refreshProjects() async {
        do {
            let allProjects = try await repository.listProjects()
            projects = activeProjectIDs.isEmpty ? allProjects : allProjects.filter { activeProjectIDs.contains($0.id) }
        } catch {
            setError("Project list failed: \(error.localizedDescription)", domain: .session)
        }
    }

    var activeHost: DeviceRecord? {
        pairedDevices.first(where: { $0.id == activeHostID })
    }

    /// A user-readable transport state. Tailscale IPv4 lives in
    /// 100.64.0.0/10; everything else is a direct local endpoint.
    var activeHostTransportLabel: String {
        guard let host = activeHost?.peerEndpoint?.host else { return "Connected" }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        if pieces.count == 4, pieces[0] == 100, (64...127).contains(pieces[1]) {
            return "Tailnet"
        }
        if host.hasSuffix(".ts.net") { return "Tailnet" }
        return "Local"
    }

    func selectHost(_ deviceID: DeviceID) async {
        guard pairedDevices.contains(where: { $0.id == deviceID && !$0.revoked }) else { return }
        activeHostID = deviceID
        UserDefaults.standard.set(deviceID.wireString, forKey: Self.activeHostDefaultsKey)
        syncedAgents = []
        activeProjectIDs = []
        await remoteConnections.setActiveDeviceID(deviceID)
        recordDebug("connection", "Active host · \(activeHost?.displayName ?? deviceID.wireString)")
        DeckHaptics.light()
    }

    func refreshApprovalState() async {
        do {
            pendingApprovalRecords = try await repository.pendingApprovals(limit: 100)
            approvalRules = try await repository.listApprovalRules(projectID: nil, sessionID: nil)
            approvalAuditEntries = try await repository.approvalAuditEntries(sessionID: nil, limit: 50)
        } catch {
            setError("Approval state failed: \(error.localizedDescription)", domain: .approval)
        }
    }

    // MARK: - Synced agent / project state (Home)

    /// A Home-tab card for one agent, built from the synced snapshot
    /// (`agent.list.response` / `agent.snapshot`) — the companion is the
    /// authority on installed state, versions, and session counts.
    struct AgentCard: Identifiable, Equatable {
        let id: AgentIdentifier
        let displayName: String
        /// Companion-reported installed state (not locally inferred).
        let installed: Bool
        let version: String?
        let activeSessionCount: Int
        let sessionCount: Int
        /// Opaque companion classification, rendered as-is.
        let reliabilityClass: String?

        /// Home rows read better in the observed-state phrasing.
        var isObservedInstalled: Bool { installed }
    }

    /// Agent cards from synced state only. Empty until the first sync
    /// lands; callers render the honest "nothing synced yet" state.
    var agentCards: [AgentCard] {
        syncedAgents.map { agent in
            AgentCard(
                id: agent.id,
                displayName: agent.displayName,
                installed: agent.installed,
                version: agent.version,
                activeSessionCount: agent.activeSessions,
                sessionCount: agent.totalSessions,
                reliabilityClass: agent.reliabilityClass.isEmpty ? nil : agent.reliabilityClass
            )
        }
    }

    var activeSessions: [SessionRecord] {
        sessions.filter(\.isActive)
    }

    // MARK: - State sync (project.list / agent.list / agent.snapshot)

    private func applyStateSync(_ message: StateSyncMessage) async {
        switch message {
        case .projectList(let payload):
            do {
                let synced = try StateSyncWire.decodeProjects(payload)
                activeProjectIDs = Set(synced.map(\.id))
                try await stateSyncMirror.mirrorProjects(synced)
                var gitStates: [ProjectID: String] = [:]
                for project in synced {
                    if let gitState = project.gitState, !gitState.isEmpty {
                        gitStates[project.id] = gitState
                    }
                }
                projectGitStates = gitStates
                await refreshProjects()
                setError(nil, domain: .session)
            } catch {
                setError("Project sync failed: \(error.localizedDescription)", domain: .session)
            }
        case .agentList(let payload), .agentSnapshot(let payload):
            do {
                let agents = try StateSyncWire.decodeAgents(payload)
                syncedAgents = agents
                syncedAgentStore.save(agents)
            } catch {
                setError("Agent sync failed: \(error.localizedDescription)", domain: .session)
            }
        }
    }

    // MARK: - Diff requests (diff.request → diff.content)

    /// Asks the companion for the session's working-tree diff. The
    /// response arrives asynchronously into `diffContents[sessionID]`.
    func requestDiff(sessionID: SessionID) async {
        // 512 KiB keeps the escaped diff text inside the 1 MiB frame cap.
        let maxBytes: Int64 = 512 * 1_024
        do {
            diffErrors[sessionID] = nil
            try await remoteConnections.sendDiffRequest(sessionID: sessionID, maxBytes: maxBytes)
        } catch IOSRemoteConnectionError.unsupportedFrame(let name) {
            diffErrors[sessionID] = "This build cannot send \(name) yet — the companion contract is still landing."
        } catch {
            diffErrors[sessionID] = "Diff request failed: \(error.localizedDescription)"
        }
    }

    private func applyDiffContent(_ payload: JSONValue) {
        do {
            let content = try StateSyncWire.decodeDiffContent(payload)
            diffContents[content.sessionID] = content
            diffErrors[content.sessionID] = nil
        } catch {
            setError("Diff response could not be decoded: \(error.localizedDescription)", domain: .session)
        }
    }

    // MARK: - Attachment uploads (composer)

    /// Uploads a picked attachment over the live connection. Transfers are
    /// serialized (the contract has no client correlation ID); progress and
    /// terminal states land in `attachmentUploads`.
    func sendAttachment(sessionID: SessionID, attachment: PickedAttachment) async {
        // Clear prior terminal uploads for this session so the composer
        // shows only the current transfer plus any in-flight ones.
        for (id, upload) in attachmentUploads
        where upload.sessionID == sessionID && upload.phase.isTerminal {
            attachmentUploads[id] = nil
        }
        let uploadID = UUID()
        attachmentUploads[uploadID] = AttachmentUpload(
            id: uploadID,
            sessionID: sessionID,
            fileName: attachment.fileName,
            totalBytes: Int64(attachment.data.count),
            sentBytes: 0,
            phase: .uploading
        )
        do {
            try await attachmentCoordinator.send(
                sessionID: sessionID,
                attachment: attachment
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, var upload = self.attachmentUploads[uploadID] else { return }
                    switch progress {
                    case .sending(let sentBytes, _):
                        upload.sentBytes = sentBytes
                    case .finalizing:
                        upload.phase = .finalizing
                    }
                    self.attachmentUploads[uploadID] = upload
                }
            }
            attachmentUploads[uploadID]?.phase = .sent
        } catch AttachmentSendError.cancelled {
            attachmentUploads[uploadID]?.phase = .cancelled
        } catch {
            attachmentUploads[uploadID]?.phase = .failed(error.localizedDescription)
        }
    }

    /// Cancels the session's active upload. The contract has no
    /// `attachment.cancel` frame, so the companion is simply abandoned.
    func cancelAttachmentUpload(_ id: UUID) async {
        guard let upload = attachmentUploads[id], !upload.phase.isTerminal else { return }
        attachmentUploads[id]?.phase = .cancelled
        await attachmentCoordinator.cancelActiveTransfer()
    }

    func dismissAttachmentUpload(_ id: UUID) {
        guard let upload = attachmentUploads[id], upload.phase.isTerminal else { return }
        attachmentUploads[id] = nil
    }

    func attachmentUploads(for sessionID: SessionID) -> [AttachmentUpload] {
        attachmentUploads.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Decoded attachment-contract responses go straight to the
    /// coordinator; malformed ones are dropped with a visible error.
    private func routeAttachmentResponse(_ response: AttachmentWireResponse) async {
        do {
            switch response {
            case .initResponse(let payload):
                await attachmentCoordinator.handleInitResponse(
                    try StateSyncWire.decodeAttachmentInitResponse(payload)
                )
            case .ack(let payload):
                await attachmentCoordinator.handleAck(
                    try StateSyncWire.decodeAttachmentAck(payload)
                )
            }
        } catch {
            setError("Attachment response could not be decoded: \(error.localizedDescription)", domain: .session)
        }
    }

    // MARK: - Terminal sessions (terminal.start / attach / resize)

    /// Latest shell PTY per project, learned from `terminal.started`.
    private(set) var projectShellSessions: [ProjectID: SessionID] = [:]
    /// In-flight `terminal.start` waits, one per project (serialized).
    private var terminalStartContinuations: [ProjectID: CheckedContinuation<TerminalStartedResponse, Error>] = [:]

    /// Agent identifier recorded locally for companion-launched shell PTYs
    /// so they appear in the Sessions list like any other session.
    private static let shellAgentID = AgentIdentifier("com.agentdeck.shell")

    /// Starts a login-shell PTY in an authorized project and waits for the
    /// companion's `terminal.started` answer (10 s ceiling). Returns nil
    /// with a visible error on failure — callers navigate only on success.
    func startTerminal(
        projectID: ProjectID,
        agentID: AgentIdentifier? = nil,
        cols: Int = 120,
        rows: Int = 32
    ) async -> SessionID? {
        guard authorizeNewLaunch() else { return nil }
        guard terminalStartContinuations[projectID] == nil else {
            setError("A shell is already starting for this project.", domain: .session)
            return nil
        }
        do {
            let response = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TerminalStartedResponse, Error>) in
                terminalStartContinuations[projectID] = continuation
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await remoteConnections.sendTerminalStart(
                            projectID: projectID,
                            agentID: agentID,
                            cols: cols,
                            rows: rows
                        )
                    } catch {
                        failTerminalStart(projectID: projectID, error: error)
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    self?.failTerminalStart(
                        projectID: projectID,
                        error: IOSRemoteConnectionError.terminalStartTimedOut
                    )
                }
            }
            setError(nil, domain: .session)
            recordSuccessfulLaunch()
            return response.sessionID
        } catch {
            setError("Shell start failed: \(error.localizedDescription)", domain: .session)
            return nil
        }
    }

    private func failTerminalStart(projectID: ProjectID, error: Error) {
        terminalStartContinuations.removeValue(forKey: projectID)?.resume(throwing: error)
    }

    /// Registers the companion's answer: the shell becomes visible in the
    /// Sessions list and any waiting `startTerminal` caller resumes.
    private func applyTerminalStarted(_ response: TerminalStartedResponse) async {
        projectShellSessions[response.projectID] = response.sessionID
        recordDebug(
            "terminal",
            "Started \(response.agentID?.rawValue ?? "shell") · session \(response.sessionID.wireString.prefix(8))"
        )
        if let continuation = terminalStartContinuations.removeValue(forKey: response.projectID) {
            continuation.resume(returning: response)
        }
        guard let sessionAgent = response.agentID ?? Self.shellAgentID else { return }
        if (try? await repository.session(id: response.sessionID)) == nil {
            let now = Date.unixMillisecondsNow
            let record = SessionRecord(
                id: response.sessionID,
                agent: sessionAgent,
                projectID: response.projectID,
                state: .ready,
                createdAt: now,
                updatedAt: now
            )
            try? await repository.insertSession(record)
            await refreshSessions()
        }
    }

    /// Attaches to a live PTY: the companion replays scrollback as isReplay
    /// `terminal.output` chunks, then live output continues. Best-effort —
    /// agent sessions have no PTY, so a missing one is not an error here.
    func attachTerminal(sessionID: SessionID) async {
        try? await remoteConnections.sendTerminalAttach(sessionID: sessionID)
    }

    /// Forwards a SwiftTerm size change to the PTY (TIOCSWINSZ). Dropped
    /// silently when disconnected: the connection status already carries
    /// that state, and the next attach replays at the current size.
    func resizeTerminal(sessionID: SessionID, cols: Int, rows: Int) async {
        try? await remoteConnections.sendTerminalResize(sessionID: sessionID, cols: cols, rows: rows)
    }

    // MARK: - Timeline (mirror-backed)

    /// Decodes mirrored timeline events for a session from the local store.
    /// Unknown future event kinds are skipped rather than crashing.
    func timelineEvents(sessionID: SessionID, limit: Int = 500) async -> [AgentEvent] {
        guard let session = try? await repository.session(id: sessionID),
              let records = try? await repository.events(
                  sessionID: sessionID,
                  afterSequence: nil,
                  limit: limit
              ) else {
            return []
        }
        return records.compactMap { record in
            try? AgentEvent(
                id: record.id,
                sessionID: record.sessionID,
                agent: session.agent,
                sequence: record.sequence,
                timestamp: record.timestamp,
                confidence: record.confidence,
                payload: AgentEventPayload(kind: record.kind, data: record.payload)
            )
        }
    }

    func pendingApproval(for sessionID: SessionID) -> ApprovalRequest? {
        pendingApprovalRecords.first { $0.request.sessionID == sessionID }?.request
    }

    // MARK: - Session control (core loop)

    /// Sends a composed prompt to a live session (`session.prompt`).
    func sendPrompt(sessionID: SessionID, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if projectShellSessions.values.contains(sessionID) {
                recordDebug("terminal", "Sending \(trimmed.utf8.count) bytes · session \(sessionID.wireString.prefix(8))")
                try await remoteConnections.sendTerminalInput(
                    sessionID: sessionID,
                    data: Data((trimmed + "\r").utf8)
                )
            } else {
                recordDebug("session", "Sending structured prompt · session \(sessionID.wireString.prefix(8))")
                try await remoteConnections.sendPrompt(sessionID: sessionID, text: trimmed)
            }
            setError(nil, domain: .session)
        } catch {
            setError("Prompt not sent: \(error.localizedDescription)", domain: .session)
        }
    }

    /// Starts a new agent session on the paired Mac (`session.start`).
    func startSession(projectID: ProjectID, agentID: AgentIdentifier, prompt: String, model: String?) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setError("A prompt is required to start a session.", domain: .session)
            return
        }
        guard authorizeNewLaunch() else { return }
        do {
            try await remoteConnections.sendSessionStart(
                projectID: projectID,
                agentID: agentID,
                prompt: trimmed,
                model: model?.isEmpty == false ? model : nil
            )
            setError(nil, domain: .session)
            recordSuccessfulLaunch()
        } catch IOSRemoteConnectionError.unsupportedFrame(let name) {
            setError("This build cannot send \(name) yet — the companion contract is still landing.", domain: .session)
        } catch {
            setError("Session start failed: \(error.localizedDescription)", domain: .session)
        }
    }

    var freeLaunchesRemaining: Int {
        if BuildChannel.isDebugUnlocked { return .max }
        return max(0, Self.freeLaunchLimit - freeLaunchCount)
    }

    @discardableResult
    func authorizeNewLaunch() -> Bool {
        guard !BuildChannel.isDebugUnlocked else { return true }
        guard subscription.isEntitled || freeLaunchCount < Self.freeLaunchLimit else {
            paywallPresented = true
            DeckHaptics.warning()
            return false
        }
        return true
    }

    private func recordSuccessfulLaunch() {
        guard !BuildChannel.isDebugUnlocked, !subscription.isEntitled else { return }
        freeLaunchCount += 1
        UserDefaults.standard.set(freeLaunchCount, forKey: "freeAgentLaunchCount")
    }

    /// Interrupts a running session (`session.interrupt`).
    func interruptSession(sessionID: SessionID) async {
        do {
            try await remoteConnections.sendInterrupt(sessionID: sessionID)
            setError(nil, domain: .session)
        } catch {
            setError("Interrupt failed: \(error.localizedDescription)", domain: .session)
        }
    }

    /// Removes retained session memory from this device. Live PTYs are
    /// interrupted first so Delete never leaves an invisible process behind.
    func deleteSession(_ session: SessionRecord) async {
        if !session.state.isTerminal {
            await interruptSession(sessionID: session.id)
        }
        do {
            _ = try await repository.deleteSession(id: session.id)
            terminalModels[session.id] = nil
            projectShellSessions = projectShellSessions.filter { $0.value != session.id }
            recordDebug("session", "Deleted session \(session.id.wireString.prefix(8))")
            await refreshSessions()
            setError(nil, domain: .session)
        } catch {
            setError("Session could not be deleted: \(error.localizedDescription)", domain: .session)
        }
    }

    // MARK: - Notification actions (§14.2)

    /// Denies the pending approval for a session from a push notification.
    /// Only low/medium-risk requests may be resolved without opening the
    /// app, and only after device-owner authentication. Approving from a
    /// notification is never offered (§15.4).
    func denyApprovalFromNotification(sessionID: SessionID) async {
        do {
            let pending = try await repository.approvals(sessionID: sessionID).filter(\.isPending)
            guard let record = pending.first else { return }
            let risk = record.request.effectiveRisk
            guard risk == .low || risk == .medium else {
                setError(
                    "This approval is \(risk.rawValue) risk — open AgentDeck to review it.",
                    domain: .approval
                )
                return
            }
            let authenticated = await authenticator.authenticate(
                reason: "Deny the pending AgentDeck action."
            )
            guard authenticated else {
                setError("Device authentication is required to deny from a notification.", domain: .approval)
                return
            }
            await resolveApproval(record.request, choice: .deny)
        } catch {
            setError("Notification deny failed: \(error.localizedDescription)", domain: .approval)
        }
    }

    /// Stops a session from a push notification after authentication.
    func interruptSessionFromNotification(sessionID: SessionID) async {
        let authenticated = await authenticator.authenticate(
            reason: "Stop the running AgentDeck session."
        )
        guard authenticated else {
            setError("Device authentication is required to stop a session from a notification.", domain: .session)
            return
        }
        await interruptSession(sessionID: sessionID)
    }

    // MARK: - Terminal models

    func terminalModel(for sessionID: SessionID) -> TerminalSessionModel {
        if let existing = terminalModels[sessionID] {
            return existing
        }
        let model = TerminalSessionModel(sessionID: sessionID)
        model.onInput = { [weak self] data in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.remoteConnections.sendTerminalInput(sessionID: sessionID, data: data)
                } catch {
                    self.setError("Terminal input failed: \(error.localizedDescription)", domain: .session)
                }
            }
        }
        model.onResize = { [weak self] cols, rows in
            Task { [weak self] in
                await self?.resizeTerminal(sessionID: sessionID, cols: cols, rows: rows)
            }
        }
        terminalModels[sessionID] = model
        return model
    }

    // MARK: - Pairing

    /// Presents the §13.2 verification phrase to the user and awaits their
    /// explicit Confirm/Reject choice. Any previously pending request is
    /// rejected first so continuations never leak.
    func requestPairingConfirmation(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        respondToPairingConfirmation(confirmed: false)
        return await withCheckedContinuation { continuation in
            pairingConfirmationContinuation = continuation
            pendingPairingConfirmation = PairingConfirmationRequest(
                phrase: phrase,
                fingerprint: fingerprint,
                peerDisplayName: peerDisplayName,
                endpoint: activePairingEndpoint
            )
        }
    }

    func respondToPairingConfirmation(confirmed: Bool) {
        let continuation = pairingConfirmationContinuation
        pairingConfirmationContinuation = nil
        pendingPairingConfirmation = nil
        continuation?.resume(returning: confirmed)
    }

    /// Pairs with a Mac using the scanned/pasted QR payload.
    func pair(with qrPayload: PairingQRPayload) async {
        guard let identity, let privateKey else {
            setError("Device identity is not ready yet — try again in a moment.", domain: .pairing)
            return
        }
        let config = PairingClientEngine.Configuration(
            identity: identity,
            privateKey: privateKey,
            displayName: "iPhone"
        )
        let engine = PairingClientEngine(
            configuration: config,
            repository: repository,
            confirmationDelegate: UIConfirmationDelegate(state: self)
        )
        activePairingEndpoint = qrPayload.endpoint.description
        defer { activePairingEndpoint = nil }
        do {
            let (outcome, connection) = try await engine.pair(qrPayload: qrPayload)
            switch outcome {
            case .paired(let deviceID):
                if let connection {
                    let config = PairingClientEngine.Configuration(
                        identity: identity,
                        privateKey: privateKey,
                        displayName: "iPhone"
                    )
                    await remoteConnections.adopt(
                        connection: connection,
                        deviceID: deviceID,
                        configuration: config
                    )
                    try? await repository.updateDeviceEndpoint(
                        deviceID,
                        endpoint: qrPayload.endpoint.description
                    )
                }
                if let connection, let token = pendingPushToken {
                    try await connection.send(
                        type: .devicePushToken,
                        payload: DevicePushTokenRequest(
                            deviceID: identity.deviceID,
                            destinationToken: token
                        ).toJSONValue()
                    )
                }
                setError(nil, domain: .pairing)
                await refreshDevices()
                await refreshFromRemoteConnection()
            case .rejected(let reason):
                setError("Pairing rejected by the Mac: \(reason.rawValue).", domain: .pairing)
            case .cancelledByUser:
                setError("Pairing cancelled — the verification phrase was not confirmed.", domain: .pairing)
            }
        } catch {
            setError("Pairing failed: \(error.localizedDescription)", domain: .pairing)
        }
    }

    /// Revokes a previously paired Mac.
    func revoke(_ device: DeviceRecord) async {
        do {
            try await repository.setDeviceRevoked(device.id, revoked: true)
            await refreshDevices()
        } catch {
            setError("Revoke failed: \(error.localizedDescription)", domain: .pairing)
        }
    }

    /// Removes a local revocation tombstone so the device can be paired
    /// again with a new QR code. This never restores an old credential.
    func forget(_ device: DeviceRecord) async {
        do {
            await remoteConnections.stop(deviceID: device.id)
            try await repository.deleteDevice(id: device.id)
            setError(nil, domain: .pairing)
            await refreshDevices()
        } catch {
            setError("Forget failed: \(error.localizedDescription)", domain: .pairing)
        }
    }

    // MARK: - Approvals

    func resolveApproval(
        _ request: ApprovalRequest,
        choice: ApprovalChoice,
        commandPattern: String? = nil
    ) async {
        do {
            let secureConfirmationPassed =
                if choice.authorizes, request.effectiveRisk.requiresSecureConfirmation {
                    await authenticator.authenticate(
                        reason: "Approve a critical AgentDeck action."
                    )
                } else {
                    false
                }
            if choice.authorizes,
               request.effectiveRisk.requiresSecureConfirmation,
               !secureConfirmationPassed {
                setError(
                    "Device authentication is required for critical approvals. "
                        + "On devices without an enrolled passcode or biometrics, critical approvals stay blocked.",
                    domain: .approval
                )
                return
            }
            let decision = try ApprovalDecision(
                choice: choice,
                commandPattern: choice == .allowCommandPatternInProject ? commandPattern : nil,
                decidedAt: Date.unixMillisecondsNow
            )
            _ = try await policyEngine.recordManualResolution(
                request: request,
                decision: decision,
                usedSecureConfirmation: secureConfirmationPassed,
                at: decision.decidedAt
            )
            try await repository.recordApprovalDecision(
                requestID: request.id,
                decision: decision,
                resolvedAt: decision.decidedAt
            )
            try? await remoteConnections.sendApprovalResolve(
                requestID: request.id,
                sessionID: request.sessionID,
                decision: decision,
                usedSecureConfirmation: secureConfirmationPassed
            )
            setError(nil, domain: .approval)
            await refreshApprovalState()
            await refreshSessions()
            publishWidgetSummary()
        } catch {
            setError("Approval resolve failed: \(error.localizedDescription)", domain: .approval)
        }
    }

    func revokeRule(_ rule: ApprovalRule) async {
        do {
            try await policyEngine.revokeRule(rule, at: Date.unixMillisecondsNow)
            await refreshApprovalState()
        } catch {
            setError("Rule revoke failed: \(error.localizedDescription)", domain: .approval)
        }
    }

    // MARK: - Notifications

    func registerPushDestinationToken(_ token: PushDestinationToken) async {
        pendingPushToken = token
    }

    func openNotificationDeepLink(_ link: NotificationDeepLink) async {
        pendingNotificationDeepLink = link
        await refreshSessions()
        switch link.eventType {
        case .approvalRequired, .agentQuestion:
            handleDeepLink(.approvals)
        case .sessionCompleted, .sessionFailed, .connectionLost, .securityWarning:
            handleDeepLink(.session(link.sessionID))
        }
    }

    func consumePendingNotificationDeepLink() -> NotificationDeepLink? {
        defer { pendingNotificationDeepLink = nil }
        return pendingNotificationDeepLink
    }

    // MARK: - Construction

    static func makeDefault() -> IOSAppState {
        let (repository, degraded) = makeRepository()
        let state = IOSAppState(
            repository: repository,
            identityStore: KeychainIdentityStore(),
            authenticator: LocalDeviceAuthenticator()
        )
        state.isStoreDegraded = degraded
        return state
    }

    /// Builds the session store, degrading gracefully to an in-memory store
    /// (with a visible banner) when the on-disk database cannot be opened.
    private static func makeRepository() -> (any SessionRepository, Bool) {
        do {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return (try SQLiteSessionStore.inMemory(), false)
            }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = base.appendingPathComponent(ProductNaming.name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (try SQLiteSessionStore(
                path: directory.appendingPathComponent("sessions.sqlite").path
            ), false)
        } catch {
            if let inMemory = try? SQLiteSessionStore.inMemory() {
                return (inMemory, true)
            }
            // Both the durable and the in-memory stores are unavailable; there
            // is no usable product in that state.
            fatalError("session store unavailable: \(error.localizedDescription)")
        }
    }
}

@MainActor
protocol DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool
}

@MainActor
private final class LocalDeviceAuthenticator: DeviceAuthenticating {
    /// Test-only seam: simulators/headless test runners often have no
    /// enrolled biometrics. Outside test runs, an unevaluable policy fails
    /// closed (Constitution: critical approvals never silently pass).
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func authenticate(reason: String) async -> Bool {
#if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.isRunningTests
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
#else
        return Self.isRunningTests
#endif
    }
}

/// Bridges the pairing engine's confirmation delegate to the UI: the user
/// compares the phrase + fingerprint with the Mac and explicitly confirms
/// or rejects. Nothing is auto-approved on the initial pairing path.
@MainActor
private final class UIConfirmationDelegate: PairingConfirmationDelegate {
    weak var state: IOSAppState?

    init(state: IOSAppState) {
        self.state = state
    }

    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        guard let state else { return false }
        return await state.requestPairingConfirmation(
            phrase: phrase,
            fingerprint: fingerprint,
            peerDisplayName: peerDisplayName
        )
    }
}
