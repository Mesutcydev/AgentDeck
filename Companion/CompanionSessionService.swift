//
//  CompanionSessionService.swift
//  Companion — AgentDeck
//
//  Owns PairingServerEngine lifecycle, adapter registration, and relay dispatch.
//

import CryptoKit
import Foundation
import Shared

@MainActor
final class CompanionSessionService {
    private let repository: any SessionRepository
    private let identityStore: KeychainIdentityStore
    private let tlsStore: TLSIdentityStore
    private let confirmationDelegate: CompanionConfirmationDelegate
    private let relayCoordinator: RelayNotificationCoordinator
    private let ptySupervisor = PTYSupervisor()
    private let terminalSequencer = TerminalBroadcastSequencer()
    private var engine: PairingServerEngine?
    private(set) var boundPort: UInt16?
    private(set) var lastError: String?

    init(
        repository: any SessionRepository,
        identityStore: KeychainIdentityStore = KeychainIdentityStore(service: "\(ProductNaming.logSubsystem).companion.identity"),
        tlsStore: TLSIdentityStore = TLSIdentityStore(service: "\(ProductNaming.logSubsystem).companion.tls"),
        confirmationDelegate: CompanionConfirmationDelegate = CompanionConfirmationDelegate(),
        relayCoordinator: RelayNotificationCoordinator
    ) {
        self.repository = repository
        self.identityStore = identityStore
        self.tlsStore = tlsStore
        self.confirmationDelegate = confirmationDelegate
        self.relayCoordinator = relayCoordinator
    }

    func refresh(acceptingConnections: Bool, discoveredAgents: [RegisteredAgent]) async {
        if acceptingConnections {
            await start(discoveredAgents: discoveredAgents)
        } else {
            await stop()
        }
    }

    func makePairingOffer() async -> PairingOffer? {
        await engine?.makeOffer()
    }

    func revoke(deviceID: DeviceID) async {
        try? await engine?.revokePeer(deviceID)
        lastError = nil
    }

    private func start(discoveredAgents: [RegisteredAgent]) async {
        guard engine == nil else { return }
        do {
            let identity = try identityStore.loadOrCreate()
            let privateKey = try identityStore.privateKey()
            let tls = try tlsStore.loadOrCreate()
            var config = PairingServerEngine.Configuration(
                identity: identity,
                privateKey: privateKey,
                tlsIdentity: tls,
                displayName: Host.current().localizedName ?? ProductNaming.name,
                listenPort: PeerEndpoint.defaultPort,
                advertisedHost: LocalNetworkAdvertisedHost.remoteAccessCurrent()
            )
            config.notificationDispatch = { [relayCoordinator] event in
                await relayCoordinator.dispatch(event: event)
            }
            let engineRef = TerminalEngineReference()
            configureStateSyncHooks(
                on: &config,
                discoveredAgents: discoveredAgents,
                engineRef: engineRef
            )
            let server = PairingServerEngine(
                configuration: config,
                repository: repository,
                confirmationDelegate: confirmationDelegate
            )
            try await server.start()
            engineRef.set(server)
            await registerAdapters(on: server, discovered: discoveredAgents)
            engine = server
            boundPort = await server.boundPort
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.logger(.transport).error("companion session service failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() async {
        guard let engine else { return }
        await engine.stop()
        self.engine = nil
        boundPort = nil
    }

    /// §29 state-sync hooks: terminal lifecycle against PTYSupervisor,
    /// project/agent inventory from the repository + discovery results,
    /// and diff mirroring through GitDiffMirror. Values are captured
    /// locally so the @Sendable closures never touch MainActor state.
    private func configureStateSyncHooks(
        on config: inout PairingServerEngine.Configuration,
        discoveredAgents: [RegisteredAgent],
        engineRef: TerminalEngineReference
    ) {
        let repository = repository
        let ptySupervisor = ptySupervisor
        let sequencer = terminalSequencer
        let launchablePairs: [(AgentIdentifier, String)] = discoveredAgents.compactMap { agent in
            guard case .installed = agent.installation.state,
                  let path = agent.installation.executablePath else { return nil }
            return (agent.id, path)
        }
        let launchableAgents: [AgentIdentifier: String] = Dictionary(uniqueKeysWithValues: launchablePairs)

        config.terminalStartHandler = { request in
            // §16 containment: the working directory comes from the
            // authorized project record — never from the wire.
            guard let project = try await repository.project(id: request.projectID) else {
                throw AgentSessionOrchestratorError.projectNotAuthorized(request.projectID)
            }
            guard let engine = engineRef.engine else {
                throw PairingError.protocolViolation("terminal stream unavailable")
            }
            let sessionID = SessionID.random()
            let executable: String
            let arguments: [String]
            if let requestedAgent = request.agentID {
                guard let providerExecutable = launchableAgents[requestedAgent] else {
                    throw PairingError.protocolViolation("requested agent is not installed")
                }
                try ExecutableIntegrityRegistry.shared.verify(executableAtPath: providerExecutable)
                executable = providerExecutable
                arguments = []
            } else {
                executable = "/bin/zsh"
                arguments = ["-l"]
            }
            let launch = PTYLaunchRequest(
                sessionID: sessionID,
                executable: executable,
                arguments: arguments,
                workingDirectory: project.canonicalPath,
                cols: request.cols,
                rows: request.rows
            )
            _ = try await ptySupervisor.launch(launch) { data in
                sequencer.enqueue(sessionID: sessionID, engine: engine, data: data)
            }
            return sessionID
        }
        config.terminalInputHandler = { sessionID, data in
            try await ptySupervisor.sendInput(sessionID: sessionID, data: data)
        }
        config.terminalResizeHandler = { sessionID, cols, rows in
            await ptySupervisor.session(for: sessionID)?.resize(cols: cols, rows: rows)
        }
        config.terminalScrollbackProvider = { sessionID in
            (try? await ptySupervisor.snapshot(sessionID: sessionID))?.scrollback
        }
        config.agentStateProvider = {
            let sessions = (try? await repository.listSessions()) ?? []
            var activeCounts: [AgentIdentifier: Int] = [:]
            var totalCounts: [AgentIdentifier: Int] = [:]
            for session in sessions {
                totalCounts[session.agent, default: 0] += 1
                if session.isActive {
                    activeCounts[session.agent, default: 0] += 1
                }
            }
            return discoveredAgents.map { agent in
                var installed = false
                var version: String?
                if case .installed(let detected) = agent.installation.state {
                    installed = true
                    version = detected
                }
                return AgentCardState(
                    id: agent.id,
                    displayName: agent.descriptor.displayName,
                    installed: installed,
                    version: version,
                    activeSessions: activeCounts[agent.id] ?? 0,
                    totalSessions: totalCounts[agent.id] ?? 0,
                    reliabilityClass: CompanionSessionService.reliabilityClass(for: agent.id)
                )
            }
        }
        config.diffProvider = { sessionID, maxBytes in
            guard let session = try await repository.session(id: sessionID),
                  let projectID = session.projectID,
                  let project = try await repository.project(id: projectID),
                  project.isGitRepository else {
                return nil
            }
            let cap = GitDiffMirror.clampedCap(maxBytes)
            let path = project.canonicalPath
            // Blocking subprocess + file IO stay off the engine actor.
            return try await Task.detached(priority: .utility) {
                try GitDiffMirror.diffHEAD(sessionID: sessionID, projectPath: path, maxBytes: cap)
            }.value
        }
    }

    /// Mirrors the `registerAdapters` switch: agents with a structured
    /// adapter report `structured`; anything else degrades honestly to
    /// `rawOnly` (§29 capability honesty).
    private nonisolated static func reliabilityClass(for id: AgentIdentifier) -> String {
        switch id.rawValue {
        case "com.openai.codex", "com.anthropic.claude-code", "com.moonshot.kimi",
             "com.anomaly.opencode", "com.xai.grok":
            "structured"
        default:
            "rawOnly"
        }
    }

    private func registerAdapters(on server: PairingServerEngine, discovered: [RegisteredAgent]) async {
        for agent in discovered {
            guard let path = agent.installation.executablePath,
                  case .installed = agent.installation.state else { continue }
            // Launch-time integrity: refuse executables replaced or tampered
            // with since discovery fingerprinted them.
            do {
                try ExecutableIntegrityRegistry.shared.verify(executableAtPath: path)
            } catch {
                lastError = error.localizedDescription
                Log.logger(.security).error(
                    "refusing to launch \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            let adapter: (any AgentAdapter)? = switch agent.id.rawValue {
            case "com.openai.codex":
                CodexAdapter(identifier: agent.id, executablePath: path)
            case "com.anthropic.claude-code":
                ClaudeAdapter(identifier: agent.id, executablePath: path)
            case "com.moonshot.kimi":
                ACPAgentAdapter.kimi(executablePath: path)
            case "com.anomaly.opencode":
                ACPAgentAdapter.opencode(executablePath: path)
            case "com.xai.grok":
                GrokAdapter(identifier: agent.id, executablePath: path)
            default:
                nil
            }
            if let adapter {
                await server.registerAgentAdapter(adapter)
            }
        }
    }
}
