//
//  CompanionSessionService.swift
//  Companion — AgentDeck
//
//  Owns PairingServerEngine lifecycle, adapter registration, and relay dispatch.
//

import AppKit
import CryptoKit
import Darwin
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
    private let localTerminalBroker = LocalTerminalBroker()
    private var engine: PairingServerEngine?
    private var localControlServer: LocalControlServer?
    private var discoveredAgents: [RegisteredAgent] = []
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
        self.discoveredAgents = discoveredAgents
        if acceptingConnections {
            await start(discoveredAgents: discoveredAgents)
        } else {
            await stop()
        }
    }

    func startLocalControl(discoveredAgents: [RegisteredAgent]) {
        self.discoveredAgents = discoveredAgents
        guard localControlServer == nil else { return }
        let server = LocalControlServer(
            handler: { [weak self] request in
                guard let self else {
                    return LocalControlAction(response: .init(requestID: request.id, ok: false, message: "Companion unavailable"))
                }
                return await self.handleLocalControl(request)
            },
            streamHandler: { [weak self] sessionID, fd, writer in
                await self?.streamLocalTerminal(sessionID: sessionID, fd: fd, writer: writer)
            }
        )
        do {
            try server.start()
            localControlServer = server
        } catch {
            lastError = "Local CLI unavailable: \(error.localizedDescription)"
        }
    }

    func makePairingOffer() async -> PairingOffer? {
        await engine?.makeOffer()
    }

    func revoke(deviceID: DeviceID) async {
        try? await engine?.revokePeer(deviceID)
        lastError = nil
    }

    func discoverExternalSessions() -> [ExternalSessionDescriptor] {
        ExternalSessionDiscovery().discover()
    }

    func handoffExternalSession(_ descriptor: ExternalSessionDescriptor, projectPath: String?) async throws -> SessionID {
        let request = LocalControlRequest(
            command: .importSession,
            provider: descriptor.providerID,
            projectPath: projectPath ?? descriptor.projectPath,
            externalSessionID: descriptor.externalSessionID
        )
        let action = await handleLocalControl(request)
        guard action.response.ok, let text = action.response.sessionID, let sessionID = SessionID(text) else {
            throw LocalControlFailure(action.response.message)
        }
        return sessionID
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

    private func handleLocalControl(_ request: LocalControlRequest) async -> LocalControlAction {
        do {
            switch request.command {
            case .status:
                let sessions = try await repository.listSessions()
                return response(request, "Companion ready · \(sessions.filter(\.isActive).count) active session(s)")
            case .open:
                NSApplication.shared.activate(ignoringOtherApps: true)
                return response(request, "Companion opened")
            case .sessions:
                return LocalControlAction(response: LocalControlResponse(
                    requestID: request.id, ok: true, message: "Session memory",
                    sessions: try await localSessionSummaries()
                ))
            case .doctor:
                let installed = discoveredAgents.filter {
                    if case .installed = $0.installation.state { return true }
                    return false
                }.map(\.descriptor.displayName).joined(separator: ", ")
                return response(request, "Socket secure · database ready · providers: \(installed.isEmpty ? "none" : installed)")
            case .run:
                let sessionID = try await launchWrappedSession(request)
                return LocalControlAction(
                    response: .init(
                        requestID: request.id, ok: true,
                        message: "AgentDeck owns this terminal session. Detach without terminating with Control-D.",
                        sessionID: sessionID.wireString, streamFollows: true
                    ),
                    streamSessionID: sessionID
                )
            case .attach:
                guard let text = request.sessionID, let sessionID = SessionID(text) else {
                    throw LocalControlFailure("A valid AgentDeck session ID is required.")
                }
                _ = try await ptySupervisor.snapshot(sessionID: sessionID)
                return LocalControlAction(
                    response: .init(
                        requestID: request.id, ok: true, message: "Attached. Detaching will not stop the agent.",
                        sessionID: sessionID.wireString, streamFollows: true
                    ),
                    streamSessionID: sessionID
                )
            case .discoverImports:
                return LocalControlAction(response: .init(
                    requestID: request.id, ok: true, message: "External session metadata",
                    imports: ExternalSessionDiscovery().discover()
                ))
            case .importSession:
                let sessionID = try await importExternalSession(request)
                return response(request, "Session handed off to AgentDeck", sessionID: sessionID)
            case .interrupt:
                guard let text = request.sessionID, let sessionID = SessionID(text) else {
                    throw LocalControlFailure("A valid session ID is required.")
                }
                await ptySupervisor.terminate(sessionID: sessionID)
                return response(request, "Interrupt requested", sessionID: sessionID)
            case .detach:
                return response(request, "Detached; the agent continues running")
            }
        } catch {
            return LocalControlAction(response: .init(
                requestID: request.id, ok: false, message: error.localizedDescription
            ))
        }
    }

    private func response(_ request: LocalControlRequest, _ message: String, sessionID: SessionID? = nil) -> LocalControlAction {
        LocalControlAction(response: .init(
            requestID: request.id, ok: true, message: message, sessionID: sessionID?.wireString
        ))
    }

    private func localSessionSummaries() async throws -> [LocalSessionSummary] {
        let sessions = try await repository.listSessions().sorted { $0.updatedAt > $1.updatedAt }
        var projects: [ProjectID: ProjectRecord] = [:]
        for session in sessions {
            if let projectID = session.projectID, projects[projectID] == nil {
                projects[projectID] = try await repository.project(id: projectID)
            }
        }
        return sessions.map {
            LocalSessionSummary(
                id: $0.id.wireString, provider: $0.agent.rawValue,
                projectPath: $0.projectID.flatMap { projects[$0]?.canonicalPath },
                state: $0.state.rawValue, origin: $0.origin.rawValue, updatedAt: $0.updatedAt
            )
        }
    }

    private func launchWrappedSession(_ request: LocalControlRequest) async throws -> SessionID {
        guard let providerText = request.provider,
              let agent = agent(forAlias: providerText),
              let executable = agent.installation.executablePath,
              case .installed = agent.installation.state else {
            throw LocalControlFailure("Provider is not installed or is not recognized.")
        }
        try ExecutableIntegrityRegistry.shared.verify(executableAtPath: executable)
        let project = try await authorizedProject(path: request.projectPath)
        let sessionID = SessionID.random()
        let now = Date.unixMillisecondsNow
        try await repository.insertSession(SessionRecord(
            id: sessionID, agent: agent.id, projectID: project.id, state: .ready,
            origin: .cliWrapper, createdAt: now, updatedAt: now
        ))
        let broker = localTerminalBroker
        let sequencer = terminalSequencer
        let engine = engine
        do {
            _ = try await ptySupervisor.launch(
                PTYLaunchRequest(
                    sessionID: sessionID, executable: executable, arguments: request.arguments,
                    workingDirectory: project.canonicalPath,
                    cols: Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "120") ?? 120,
                    rows: Int(ProcessInfo.processInfo.environment["LINES"] ?? "30") ?? 30
                ),
                outputHandler: { data in
                    Task { await broker.publish(sessionID: sessionID, data: data) }
                    if let engine { sequencer.enqueue(sessionID: sessionID, engine: engine, data: data) }
                },
                terminationHandler: { [repository] status in
                    Task {
                        try? await repository.updateSessionState(
                            id: sessionID, state: status == 0 ? .completed : .failed,
                            updatedAt: Date.unixMillisecondsNow, endedAt: Date.unixMillisecondsNow,
                            completionSummary: "CLI exited with status \(status)"
                        )
                    }
                }
            )
            return sessionID
        } catch {
            try? await repository.updateSessionState(
                id: sessionID, state: .failed, updatedAt: Date.unixMillisecondsNow,
                endedAt: Date.unixMillisecondsNow, completionSummary: error.localizedDescription
            )
            throw error
        }
    }

    private func streamLocalTerminal(sessionID: SessionID, fd: Int32, writer: LocalSocketWriter) async {
        if let snapshot = try? await ptySupervisor.snapshot(sessionID: sessionID), !snapshot.scrollback.isEmpty {
            guard writeLocalTerminalOutput(snapshot.scrollback, writer: writer) else { return }
        }
        let token = await localTerminalBroker.subscribe(sessionID: sessionID) { data in
            _ = self.writeLocalTerminalOutput(data, writer: writer)
        }
        defer { Task { await localTerminalBroker.unsubscribe(sessionID: sessionID, token: token) } }
        while let line = LocalControlServer.readLine(
            fd: fd,
            maximumBytes: LocalControlRequest.maximumEncodedBytes
        ) {
            guard let packet = try? JSONDecoder().decode(LocalTerminalMessage.self, from: line),
                  packet.version == LocalControlRequest.currentVersion else {
                _ = writer.writeJSONLine(LocalTerminalMessage(kind: .error, message: "Invalid terminal packet."))
                break
            }
            switch packet.kind {
            case .input:
                if let data = packet.data, !data.isEmpty {
                    try? await ptySupervisor.sendInput(sessionID: sessionID, data: data)
                }
            case .resize:
                if let columns = packet.columns, let rows = packet.rows,
                   (1...1_000).contains(columns), (1...1_000).contains(rows) {
                    await ptySupervisor.session(for: sessionID)?.resize(cols: columns, rows: rows)
                }
            case .interrupt:
                try? await ptySupervisor.sendInput(sessionID: sessionID, data: Data([0x03]))
            case .detach:
                return
            case .output, .error:
                _ = writer.writeJSONLine(LocalTerminalMessage(kind: .error, message: "Client sent an invalid terminal packet kind."))
                return
            }
        }
    }

    private nonisolated func writeLocalTerminalOutput(_ data: Data, writer: LocalSocketWriter) -> Bool {
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            guard writer.writeJSONLine(LocalTerminalMessage(kind: .output, data: data.subdata(in: offset..<end))) else {
                return false
            }
            offset = end
        }
        return true
    }

    private func importExternalSession(_ request: LocalControlRequest) async throws -> SessionID {
        guard let provider = request.provider, let externalID = request.externalSessionID else {
            throw LocalControlFailure("Provider and external session ID are required.")
        }
        guard let descriptor = ExternalSessionDiscovery().discover(limit: 100).first(where: {
            $0.providerID == provider && $0.externalSessionID == externalID
        }) else { throw LocalControlFailure("The external session is no longer available.") }
        guard descriptor.canResume else { throw LocalControlFailure("This provider does not support safe external handoff.") }
        guard descriptor.processState != .active else {
            throw LocalControlFailure("Exit the original terminal agent first, then retry the handoff.")
        }
        guard let agentID = AgentIdentifier(provider), agent(forID: agentID) != nil else {
            throw LocalControlFailure("The matching provider is not installed.")
        }
        let existing = try await repository.listSessions().contains {
            $0.providerSessionReference?.providerID == agentID &&
            $0.providerSessionReference?.externalSessionID == externalID
        }
        guard !existing else { throw LocalControlFailure("This provider session is already in AgentDeck.") }
        guard let engine else { throw LocalControlFailure("Remote access must be running to import structured sessions.") }
        let project = try await authorizedProject(path: request.projectPath ?? descriptor.projectPath)
        let reference = ProviderSessionReference(
            providerID: agentID, externalSessionID: externalID,
            compatibilityVersion: descriptor.compatibilityVersion, importedAt: Date.unixMillisecondsNow
        )
        return try await engine.startAgentSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(
                projectID: project.id, workingDirectory: project.canonicalPath,
                origin: .externalImport, providerSessionReference: reference
            )
        )
    }

    private func authorizedProject(path: String?) async throws -> ProjectRecord {
        guard let path else { throw LocalControlFailure("Use --project with an authorized project path.") }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard let project = try await repository.project(matchingCanonicalPath: canonical) else {
            throw LocalControlFailure("Authorize this project in AgentDeck Companion before launching it from the CLI.")
        }
        return project
    }

    private func agent(forAlias alias: String) -> RegisteredAgent? {
        let normalized = alias.lowercased()
        let id: String = switch normalized {
        case "claude", "claude-code": "com.anthropic.claude-code"
        case "codex": "com.openai.codex"
        case "grok": "com.xai.grok"
        case "kimi", "kimi-code": "com.moonshot.kimi"
        case "opencode": "com.anomaly.opencode"
        default: normalized
        }
        return discoveredAgents.first { $0.id.rawValue == id }
    }

    private func agent(forID id: AgentIdentifier) -> RegisteredAgent? {
        discoveredAgents.first { $0.id == id }
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
                ACPAgentAdapter(
                    identifier: agent.id,
                    executablePath: path,
                    launchProfile: .grok
                )
            default:
                nil
            }
            if let adapter {
                await server.registerAgentAdapter(adapter)
            }
        }
    }
}

private struct LocalControlFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
