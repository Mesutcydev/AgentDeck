//
//  AppState.swift
//  Companion — AgentDeck
//
//  The companion's status model (§12.1, §12.6): onboarding flag, Pause
//  Remote Access (persisted, §12.6), menu counts, connection-service
//  statuses, login-item state. Networking/pairing are Phase 3 — this
//  model exposes the seams, nothing more.
//

import AppKit
import Foundation
import Observation
import Shared

/// §12.6 connection-service status lines (Tailscale, Cloudflare).
enum ConnectionServiceStatus: String, Sendable {
    case notConfigured
    case unavailable
    case reachable

    var menuDescription: String {
        switch self {
        case .notConfigured: "Not configured"
        case .unavailable: "Unavailable"
        case .reachable: "Reachable"
        }
    }
}

@MainActor @Observable
final class AppState {
    /// True when running inside XCTest (app-hosted tests): no windows, no
    /// real user defaults database writes outside a temp suite.
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    enum DefaultsKey {
        static let onboardingCompleted = "onboardingCompleted"
        static let remoteAccessPaused = "remoteAccessPaused"
        static let relayBaseURLString = "relayBaseURLString"
    }

    // MARK: - Persisted state (§12.1 onboarding shown once; §12.6 Pause)

    private(set) var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: DefaultsKey.onboardingCompleted) }
    }

    private(set) var remoteAccessPaused: Bool {
        didSet { defaults.set(remoteAccessPaused, forKey: DefaultsKey.remoteAccessPaused) }
    }

    // MARK: - Live status (real sources; counts come from the session store)

    private(set) var pairedDeviceCount = 0
    private(set) var activeSessionCount = 0
    private(set) var pendingApprovalCount = 0
    private(set) var tailscaleStatus: ConnectionServiceStatus = .notConfigured
    private(set) var cloudflareStatus: ConnectionServiceStatus = .notConfigured
    private(set) var loginItemStatus: LoginItemStatus
    /// Durable session history read from the Application Support SQLite
    /// database. Newest activity appears first; it survives app relaunches.
    private(set) var recentSessions: [SessionRecord] = []
    private(set) var projectsByID: [ProjectID: ProjectRecord] = [:]
    private(set) var approvalRules: [ApprovalRule] = []

    // MARK: - Dependencies (injected)

    private let defaults: UserDefaults
    private let loginItemManager: any LoginItemManaging
    private let repository: (any SessionRepository)?
    let recorder: DiagnosticsRecorder
    let projectWorkspace: ProjectWorkspace?
    private(set) var sessionService: CompanionSessionService?
    private(set) var pairedDevices: [DeviceRecord] = []
    private(set) var pairingWindowOpen = false
    let sparkleController = SparkleUpdateController()

    /// §14.3 relay endpoint; nil means background alerts are disabled.
    private(set) var relayBaseURL: URL?
    private var relayCoordinator: RelayNotificationCoordinator?

    init(
        defaults: UserDefaults,
        loginItemManager: any LoginItemManaging,
        repository: (any SessionRepository)?,
        recorder: DiagnosticsRecorder
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager
        self.repository = repository
        self.recorder = recorder
        self.projectWorkspace = repository.map {
            ProjectWorkspace(repository: $0, folderPicker: SystemFolderPicker())
        }
        self.relayBaseURL = Self.resolveRelayBaseURL(defaults: defaults)
        if let repository {
            let relay = RelayNotificationCoordinator(repository: repository, recorder: recorder)
            self.relayCoordinator = relay
            self.sessionService = CompanionSessionService(
                repository: repository,
                relayCoordinator: relay
            )
        } else {
            self.relayCoordinator = nil
            self.sessionService = nil
        }
        self.onboardingCompleted = defaults.bool(forKey: DefaultsKey.onboardingCompleted)
        self.remoteAccessPaused = defaults.bool(forKey: DefaultsKey.remoteAccessPaused)
        self.loginItemStatus = loginItemManager.status
        configureRelay()
    }

    // MARK: - Derived state

    /// §12.6: Pause rejects new connections; honored by the Phase 3
    /// transport through this seam.
    var isAcceptingConnections: Bool { !remoteAccessPaused }

    // MARK: - Lifecycle

    /// Called once at app start: activation policy + initial counts.
    func start() async {
        applyActivationPolicy()
        Log.logger(.session).info("companion started (paused: \(self.remoteAccessPaused, privacy: .public))")
        await recorder.record(
            category: .session, level: .info,
            message: "companion started; paused=\(remoteAccessPaused)"
        )
        await refreshStatus()
        await projectWorkspace?.refresh()
        if let sessionService, let workspace = projectWorkspace {
            await sessionService.refresh(
                acceptingConnections: isAcceptingConnections,
                discoveredAgents: workspace.discoveredAgents
            )
        }
    }

    /// §12.1: accessory activation policy (no Dock icon) after onboarding;
    /// regular policy while the one-time onboarding window is up. Under
    /// XCTest the app always runs accessory — tests never flash UI.
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy =
            if AppState.isRunningTests {
                .accessory
            } else if onboardingCompleted {
                .accessory
            } else {
                .regular
            }
        NSApplication.shared.setActivationPolicy(policy)
    }

    // MARK: - Onboarding

    func completeOnboarding() async {
        onboardingCompleted = true
        applyActivationPolicy()
        await recorder.record(category: .session, level: .info, message: "onboarding completed")
    }

    // MARK: - Pause Remote Access (§12.6)

    func setPaused(_ paused: Bool) async {
        remoteAccessPaused = paused
        Log.logger(.transport).notice("remote access paused: \(paused, privacy: .public)")
        await recorder.record(
            category: .transport, level: .notice,
            message: "remote access \(paused ? "paused" : "resumed")"
        )
        if let sessionService, let workspace = projectWorkspace {
            await sessionService.refresh(
                acceptingConnections: isAcceptingConnections,
                discoveredAgents: workspace.discoveredAgents
            )
        }
    }

    // MARK: - Notification relay (§14.3)

    /// Typical value for a locally-run development relay.
    static var localDevelopmentRelayURL: URL? { URL(string: "http://127.0.0.1:8787") }

    /// Persists a new relay endpoint and reconfigures dispatch. Pass nil
    /// to disable background alerts.
    func setRelayBaseURL(_ url: URL?) async {
        let sanitized = Self.sanitizeRelayBaseURL(url)
        relayBaseURL = sanitized
        if let sanitized {
            defaults.set(sanitized.absoluteString, forKey: DefaultsKey.relayBaseURLString)
        } else {
            defaults.removeObject(forKey: DefaultsKey.relayBaseURLString)
        }
        configureRelay()
        await recorder.record(
            category: .session, level: .info,
            message: "relay base URL set to \(sanitized?.absoluteString ?? "none (relay disabled)")"
        )
    }

    /// Resolves the configured endpoint: `AGENTDECK_RELAY_URL` overrides
    /// for development; otherwise the persisted setting. Absent or
    /// non-http(s) values disable the relay.
    static func resolveRelayBaseURL(defaults: UserDefaults) -> URL? {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_RELAY_URL"] {
            return sanitizeRelayBaseURL(URL(string: override))
        }
        return sanitizeRelayBaseURL(defaults.string(forKey: DefaultsKey.relayBaseURLString).flatMap(URL.init(string:)))
    }

    static func sanitizeRelayBaseURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func configureRelay() {
        guard let relayCoordinator else { return }
        guard let relayBaseURL else {
            relayCoordinator.configure(nil)
            Log.logger(.session).info("notification relay disabled (no relay URL configured)")
            return
        }
        do {
            let key = try RelayNotificationCoordinator.loadOrCreateSigningKey(defaults: defaults)
            relayCoordinator.configure(.init(relayBaseURL: relayBaseURL, signingPrivateKey: key))
            Log.logger(.session).info("notification relay configured: \(relayBaseURL.absoluteString, privacy: .public)")
        } catch {
            relayCoordinator.configure(nil)
            Log.logger(.session).error("relay signing key unavailable; relay disabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Start at Login (§12.2)

    func setLoginItemEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try loginItemManager.register()
            } else {
                try await loginItemManager.unregister()
            }
        } catch {
            Log.logger(.session).error("login item update failed: \(error.localizedDescription, privacy: .public)")
            await recorder.record(
                category: .session, level: .error,
                message: "login item update failed: \(error.localizedDescription)"
            )
        }
        loginItemStatus = loginItemManager.status
    }

    func refreshLoginItemStatus() {
        loginItemStatus = loginItemManager.status
    }

    // MARK: - Status refresh (menu counts, §12.6)

    func refreshStatus() async {
        let detectedTailscaleStatus = ConnectionServiceDetector.tailscaleStatus()
        if detectedTailscaleStatus != tailscaleStatus {
            Log.logger(.transport).info(
                "Tailscale status: \(detectedTailscaleStatus.rawValue, privacy: .public)"
            )
        }
        tailscaleStatus = detectedTailscaleStatus
        guard let repository else { return }
        do {
            async let active = repository.countActiveSessions()
            async let pending = repository.countPendingApprovals()
            async let devices = repository.listDevices()
            async let sessions = repository.listSessions()
            async let projects = repository.listProjects()
            async let rules = repository.listApprovalRules(projectID: nil, sessionID: nil)
            activeSessionCount = try await active
            pendingApprovalCount = try await pending
            pairedDevices = try await devices.filter { !$0.revoked }
            pairedDeviceCount = pairedDevices.count
            recentSessions = try await sessions.sorted { $0.updatedAt > $1.updatedAt }
            projectsByID = try await Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            approvalRules = try await rules.filter { $0.isActive(at: Date.unixMillisecondsNow) }
        } catch {
            Log.logger(.session).error("status refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLoginItemStatus()
    }

    func events(for sessionID: SessionID) async -> [EventRecord] {
        guard let repository else { return [] }
        do {
            return try await repository.events(sessionID: sessionID, afterSequence: nil, limit: 500)
        } catch {
            await recorder.record(
                category: .session,
                level: .error,
                message: "session history load failed: \(error.localizedDescription)"
            )
            return []
        }
    }

    func deleteSession(_ session: SessionRecord) async {
        guard let repository else { return }
        do {
            _ = try await repository.deleteSession(id: session.id)
            await refreshStatus()
        } catch {
            await recorder.record(
                category: .session,
                level: .error,
                message: "session deletion failed: \(error.localizedDescription)"
            )
        }
    }

    func revokeApprovalRule(_ rule: ApprovalRule) async {
        guard let repository else { return }
        do {
            try await repository.revokeApprovalRule(id: rule.id, revokedAt: Date.unixMillisecondsNow)
            await refreshStatus()
        } catch {
            await recorder.record(
                category: .approval,
                level: .error,
                message: "approval rule revocation failed: \(error.localizedDescription)"
            )
        }
    }

    func openPairingWindow() {
        pairingWindowOpen = true
    }

    func closePairingWindow() {
        pairingWindowOpen = false
    }

    func revokePairedDevice(_ device: DeviceRecord) async {
        await sessionService?.revoke(deviceID: device.id)
        await refreshStatus()
    }

    // MARK: - Diagnostics export (§12.2)

    func buildDiagnosticsReport() async -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: Date.unixMillisecondsNow,
            statusFields: [
                ("onboardingCompleted", .bool(onboardingCompleted)),
                ("remoteAccessPaused", .bool(remoteAccessPaused)),
                ("pairedDevices", .int(Int64(pairedDeviceCount))),
                ("activeSessions", .int(Int64(activeSessionCount))),
                ("pendingApprovals", .int(Int64(pendingApprovalCount))),
                ("tailscale", .string(tailscaleStatus.rawValue)),
                ("cloudflare", .string(cloudflareStatus.rawValue)),
                ("loginItem", .string(loginItemStatus.rawValue))
            ],
            recentDiagnostics: await recorder.recentEntries(limit: 100)
        )
    }

    // MARK: - Default construction

    /// Wires the real dependencies: SMAppService login item, the §12.5
    /// SQLite store in Application Support, the diagnostics recorder.
    static func makeDefault() -> AppState {
        let recorder = DiagnosticsRecorder()
        let repository: (any SessionRepository)? = makeRepository()
        return AppState(
            defaults: .standard,
            loginItemManager: SystemLoginItemManager(),
            repository: repository,
            recorder: recorder
        )
    }

    private static func makeRepository() -> (any SessionRepository)? {
        do {
            if isRunningTests {
                return try SQLiteSessionStore.inMemory()
            }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = base.appendingPathComponent(ProductNaming.name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try SQLiteSessionStore(
                path: directory.appendingPathComponent("sessions.sqlite").path
            )
        } catch {
            Log.logger(.session).fault("session store unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
