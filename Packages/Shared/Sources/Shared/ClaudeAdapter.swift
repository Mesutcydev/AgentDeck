//
//  ClaudeAdapter.swift
//  Shared — AgentDeck
//
//  §29 Phase 7 Claude Code adapter: turn-based stream-json integration using
//  `--session-id` / `--resume`, a managed PreToolUse hook side-channel for
//  explicit allow/deny approvals, and a PTY raw-terminal fallback.
//

import Foundation

#if os(macOS)

public enum ClaudeLaunchMode: Sendable {
    case automatic
    case forcePTYFallback
}

public enum ClaudeAdapterError: Error, Equatable {
    case sessionNotFound(SessionID)
    case turnAlreadyRunning(SessionID)
    case approvalNotFound(ApprovalRequestID)
    case launchFailed(String)
}

public actor ClaudeAdapter: AgentAdapter {
    public let identifier: AgentIdentifier
    public let capabilities: AgentCapabilities
    public nonisolated let externalSessionCapabilities = ExternalSessionCapabilities(
        discovery: .supported,
        importing: .supported
    )

    private let executablePath: String
    private let hookManager: ClaudeHookManager?
    private let hookInstallApprovalGranted: Bool
    private let launchMode: ClaudeLaunchMode
    private let ptySupervisor: PTYSupervisor
    private let environmentOverrides: [String: String]

    /// Documented environment additions for Claude Code only: Anthropic
    /// credentials/config (`ANTHROPIC_API_KEY`, base URL, …) and Claude
    /// Code's own `CLAUDE_CODE_*` knobs. Nothing else leaks from the
    /// companion environment.
    private static let environmentPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_"]

    private struct ClaudeSession {
        let handle: AgentSessionHandle
        let projectID: ProjectID
        let workingDirectory: String
        let model: String?
        let providerSessionID: String
        let hookDirectory: URL
        var continuation: AsyncStream<AgentEvent>.Continuation?
        var hookMonitorTask: Task<Void, Never>?
        var seenRequestFiles: Set<String> = []
        var pendingApprovals: [ApprovalRequestID: URL] = [:]
        var currentTurnID: UUID?
        var currentTurnDirectory: URL?
        var currentProcess: Process?
        var ptyPumpTask: Task<Void, Never>?
        var turnMode: TurnMode?
        var turnEmittedTerminalEvent = false
        var hasExecutedTurn = false
    }

    private enum TurnMode {
        case structured
        case pty
    }

    private var sessions: [SessionID: ClaudeSession] = [:]

    public init(
        identifier: AgentIdentifier,
        executablePath: String,
        hookManager: ClaudeHookManager? = nil,
        hookInstallApprovalGranted: Bool = false,
        launchMode: ClaudeLaunchMode = .automatic,
        ptySupervisor: PTYSupervisor = PTYSupervisor(),
        environmentOverrides: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.executablePath = executablePath
        self.hookManager = hookManager
        self.hookInstallApprovalGranted = hookInstallApprovalGranted
        self.launchMode = launchMode
        self.ptySupervisor = ptySupervisor
        self.environmentOverrides = environmentOverrides
        self.capabilities = AgentCapabilities(
            structuredEvents: true,
            approvals: true,
            sessionResume: true,
            cancellation: true,
            streaming: true
        )
    }

    public func inspectInstallation() async -> AgentInstallation {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return AgentInstallation(state: .notInstalled, executablePath: nil)
        }
        do {
            let version = try Self.runVersion(executablePath: executablePath)
            return AgentInstallation(
                state: .installed(version: version.isEmpty ? "unknown" : version),
                executablePath: executablePath
            )
        } catch {
            return AgentInstallation(
                state: .broken(reason: error.localizedDescription),
                executablePath: executablePath
            )
        }
    }

    public func inspectAuthentication() async -> AgentAuthenticationState {
        .authenticated
    }

    public func launch(configuration: AgentLaunchConfiguration) async throws -> AgentSessionStream {
        if let hookManager {
            try await hookManager.installHooks(explicitApprovalGranted: hookInstallApprovalGranted)
        }

        let sessionID = configuration.sessionID
        let handle = AgentSessionHandle(sessionID: sessionID, agent: identifier)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-claude-\(sessionID.wireString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        // Hook request/response files carry approval state: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookDirectory.path)

        var eventContinuation: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }

        let monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollHookRequests(sessionID: sessionID)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let importedReference = configuration.providerSessionReference
        sessions[sessionID] = ClaudeSession(
            handle: handle,
            projectID: configuration.projectID,
            workingDirectory: configuration.workingDirectory,
            model: configuration.model,
            providerSessionID: importedReference?.externalSessionID ?? sessionID.wireString,
            hookDirectory: hookDirectory,
            continuation: eventContinuation,
            hookMonitorTask: monitorTask,
            hasExecutedTurn: importedReference != nil
        )

        if let prompt = configuration.initialPrompt {
            do {
                try await beginTurn(prompt: prompt, sessionID: sessionID)
            } catch {
                // Failure path must clean up exactly like terminate() does.
                sessions.removeValue(forKey: sessionID)
                monitorTask.cancel()
                eventContinuation?.finish()
                try? FileManager.default.removeItem(at: hookDirectory)
                throw error
            }
        }

        return AgentSessionStream(handle: handle, events: events)
    }

    public func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {
        switch input {
        case .prompt(let prompt):
            try await beginTurn(prompt: prompt, sessionID: session.sessionID)
        }
    }

    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {
        guard var claude = sessions[session.sessionID] else {
            throw ClaudeAdapterError.approvalNotFound(requestID)
        }
        let responseURL = claude.pendingApprovals.removeValue(forKey: requestID)
            ?? claude.currentTurnDirectory?.appendingPathComponent("response-\(requestID.wireString).json")
        guard let responseURL else {
            throw ClaudeAdapterError.approvalNotFound(requestID)
        }

        let reply: [String: Any] = [
            "decision": decision.choice.authorizes ? "allow" : "deny",
            "message": decision.choice.authorizes ? "Approved by AgentDeck" : "Denied by AgentDeck"
        ]
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        try Self.writeHookResponseFile(data, to: responseURL)
        sessions[session.sessionID] = claude
    }

    /// Writes the hook response atomically with owner-only permissions; the
    /// Python hook polls for this file to learn the allow/deny decision.
    static func writeHookResponseFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func interrupt(session: AgentSessionHandle) async throws {
        guard let claude = sessions[session.sessionID] else {
            throw ClaudeAdapterError.sessionNotFound(session.sessionID)
        }
        switch claude.turnMode {
        case .structured:
            if let process = claude.currentProcess {
                ProcessGroupTerminator.terminateTree(process: process)
            }
        case .pty:
            await ptySupervisor.terminate(sessionID: session.sessionID)
        case nil:
            break
        }
    }

    public func resume(session: AgentSessionHandle) async throws {
        guard sessions[session.sessionID] != nil else {
            throw ClaudeAdapterError.sessionNotFound(session.sessionID)
        }
        // Claude's headless flow is turn-based: every send after the first
        // automatically uses `--resume <session-id>`, so explicit resume is a
        // no-op until a richer UI asks for the next prompt.
    }

    public func terminate(session: AgentSessionHandle) async throws {
        guard let claude = sessions.removeValue(forKey: session.sessionID) else { return }
        claude.hookMonitorTask?.cancel()
        claude.ptyPumpTask?.cancel()
        switch claude.turnMode {
        case .structured:
            if let process = claude.currentProcess {
                ProcessGroupTerminator.terminateTree(process: process)
            }
        case .pty:
            await ptySupervisor.terminate(sessionID: session.sessionID)
        case nil:
            break
        }
        claude.continuation?.finish()
        try? FileManager.default.removeItem(at: claude.hookDirectory)
    }

    private func beginTurn(prompt: PromptInput, sessionID: SessionID) async throws {
        guard var claude = sessions[sessionID] else {
            throw ClaudeAdapterError.sessionNotFound(sessionID)
        }
        guard claude.turnMode == nil else {
            throw ClaudeAdapterError.turnAlreadyRunning(sessionID)
        }

        let turnID = UUID()
        let turnDirectory = claude.hookDirectory.appendingPathComponent(turnID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: turnDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: turnDirectory.path)
        claude.currentTurnID = turnID
        claude.currentTurnDirectory = turnDirectory
        claude.seenRequestFiles.removeAll(keepingCapacity: true)
        claude.pendingApprovals.removeAll(keepingCapacity: true)
        claude.turnEmittedTerminalEvent = false
        do {
            switch launchMode {
            case .automatic:
                claude.currentProcess = try startStructuredTurn(
                    prompt: prompt,
                    session: claude,
                    turnID: turnID,
                    turnDirectory: turnDirectory
                )
                claude.turnMode = .structured
            case .forcePTYFallback:
                claude.ptyPumpTask = try await startPTYTurn(
                    prompt: prompt,
                    session: claude,
                    turnID: turnID,
                    turnDirectory: turnDirectory
                )
                claude.turnMode = .pty
            }
        } catch {
            // Launch failure: reset state and remove the per-turn directory
            // instead of leaking hook scaffolding.
            claude.currentTurnID = nil
            claude.currentTurnDirectory = nil
            claude.turnMode = nil
            claude.ptyPumpTask = nil
            sessions[sessionID] = claude
            cleanupHookDirectory(turnDirectory)
            try? FileManager.default.removeItem(at: turnDirectory)
            throw error
        }
        claude.hasExecutedTurn = true
        sessions[sessionID] = claude
    }

    private func startStructuredTurn(
        prompt: PromptInput,
        session: ClaudeSession,
        turnID: UUID,
        turnDirectory: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = structuredArguments(for: prompt, session: session)
        process.currentDirectoryURL = URL(fileURLWithPath: session.workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = AgentEnvironment.sanitizedForAgent(
            additionalPrefixes: Self.environmentPrefixes,
            overrides: environmentOverrides
        )
        environment["AGENTDECK_CLAUDE_HOOK_DIR"] = turnDirectory.path
        if environment["AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS"] == nil {
            environment["AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS"] = "300"
        }
        process.environment = environment

        // Completed lines from both pipes funnel into one serialized stream;
        // a single consumer task applies them to actor state in order —
        // no per-line fire-and-forget tasks.
        let sessionID = session.handle.sessionID
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        let (lineStream, lineSink) = AsyncStream<StructuredPipeLine>.makeStream(bufferingPolicy: .unbounded)
        let openPipes = OpenPipeCounter(count: 2)
        let onPipeEnd: @Sendable () -> Void = {
            if openPipes.decrementAndCheckDrained() {
                lineSink.finish()
            }
        }
        let stdoutDrainer = StructuredPipeDrainer(isStdErr: false, sink: lineSink, onPipeEnd: onPipeEnd)
        let stderrDrainer = StructuredPipeDrainer(isStdErr: true, sink: lineSink, onPipeEnd: onPipeEnd)
        stdoutDrainer.attach(to: stdout)
        stderrDrainer.attach(to: stderr)
        let readTask = Task { [weak self] in
            for await line in lineStream {
                if line.isStdErr {
                    await self?.emitStderrLine(line.text, sessionID: sessionID, turnID: turnID)
                } else {
                    await self?.consumeStructuredLine(line.text, sessionID: sessionID, turnID: turnID)
                }
            }
        }
        process.terminationHandler = { [weak self] proc in
            stdoutDrainer.stop(stdout)
            stderrDrainer.stop(stderr)
            Task {
                await self?.structuredTurnDidExit(
                    sessionID: sessionID,
                    turnID: turnID,
                    turnDirectory: turnDirectory,
                    status: proc.terminationStatus
                )
            }
        }

        do {
            try process.run()
            ProcessGroupTerminator.makeGroupLeader(processIdentifier: process.processIdentifier)
            return process
        } catch {
            stdoutDrainer.stop(stdout)
            stderrDrainer.stop(stderr)
            readTask.cancel()
            throw ClaudeAdapterError.launchFailed(error.localizedDescription)
        }
    }

    private func structuredArguments(for prompt: PromptInput, session: ClaudeSession) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "dontAsk"
        ]
        if let model = session.model {
            arguments += ["--model", model]
        }
        if session.hasExecutedTurn {
            arguments += ["--resume", session.providerSessionID]
        } else {
            arguments += ["--session-id", session.providerSessionID]
        }
        arguments.append(prompt.text)
        return arguments
    }

    /// Serialized PTY turn events: output chunks and the exit signal share
    /// one stream so ordering is preserved end-to-end.
    private enum PTYTurnEvent: Sendable {
        case output(Data)
        case exited(Int32)
    }

    /// Returns the pump task consuming the serialized PTY event stream.
    private func startPTYTurn(
        prompt: PromptInput,
        session: ClaudeSession,
        turnID: UUID,
        turnDirectory: URL
    ) async throws -> Task<Void, Never> {
        let sessionID = session.handle.sessionID
        let request = PTYLaunchRequest(
            sessionID: sessionID,
            executable: executablePath,
            arguments: ptyArguments(for: prompt, session: session),
            environment: mergedEnvironment(),
            workingDirectory: session.workingDirectory
        )
        let (eventStream, eventSink) = AsyncStream<PTYTurnEvent>.makeStream(bufferingPolicy: .unbounded)
        do {
            _ = try await ptySupervisor.launch(
                request,
                outputHandler: { data in
                    eventSink.yield(.output(data))
                },
                terminationHandler: { status in
                    eventSink.yield(.exited(status))
                    eventSink.finish()
                }
            )
        } catch {
            eventSink.finish()
            throw ClaudeAdapterError.launchFailed(error.localizedDescription)
        }
        return Task { [weak self] in
            for await event in eventStream {
                switch event {
                case .output(let data):
                    await self?.handlePTYOutput(sessionID: sessionID, turnID: turnID, data: data)
                case .exited(let status):
                    await self?.handlePTYExit(
                        sessionID: sessionID,
                        turnID: turnID,
                        turnDirectory: turnDirectory,
                        status: status
                    )
                }
            }
        }
    }

    private func ptyArguments(for prompt: PromptInput, session: ClaudeSession) -> [String] {
        var arguments: [String] = []
        if let model = session.model {
            arguments += ["--model", model]
        }
        if session.hasExecutedTurn {
            arguments += ["--resume", session.providerSessionID]
        } else {
            arguments += ["--session-id", session.providerSessionID]
        }
        arguments.append(prompt.text)
        return arguments
    }

    /// One completed pipe line tagged with its source stream.
    private struct StructuredPipeLine: Sendable {
        let isStdErr: Bool
        let text: String
    }

    /// Counts still-open pipes so the serialized line stream finishes only
    /// after both stdout and stderr reach EOF (or are stopped).
    private final class OpenPipeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int

        init(count: Int) {
            remaining = count
        }

        func decrementAndCheckDrained() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            remaining = max(0, remaining - 1)
            return remaining == 0
        }
    }

    /// Reads one pipe, accumulates bytes in a bounded line buffer, and
    /// yields completed lines into the shared serialized stream. All mutable
    /// state is guarded by `lock`; no per-line tasks are spawned.
    private final class StructuredPipeDrainer: @unchecked Sendable {
        private let lock = NSLock()
        private var reader = BoundedLineBuffer()
        private var ended = false
        private let isStdErr: Bool
        private let sink: AsyncStream<StructuredPipeLine>.Continuation
        private let onPipeEnd: @Sendable () -> Void

        init(
            isStdErr: Bool,
            sink: AsyncStream<StructuredPipeLine>.Continuation,
            onPipeEnd: @escaping @Sendable () -> Void
        ) {
            self.isStdErr = isStdErr
            self.sink = sink
            self.onPipeEnd = onPipeEnd
        }

        func attach(to handle: FileHandle) {
            handle.readabilityHandler = { [weak self] fileHandle in
                self?.readAvailable(fileHandle)
            }
        }

        func stop(_ handle: FileHandle) {
            handle.readabilityHandler = nil
            markEnded()
        }

        private func readAvailable(_ fileHandle: FileHandle) {
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                markEnded()
                return
            }
            lock.lock()
            let lines = reader.append(chunk)
            lock.unlock()
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                sink.yield(StructuredPipeLine(isStdErr: isStdErr, text: line))
            }
        }

        private func markEnded() {
            lock.lock()
            let alreadyEnded = ended
            ended = true
            lock.unlock()
            if !alreadyEnded {
                onPipeEnd()
            }
        }
    }

    private func consumeStructuredLine(_ line: String, sessionID: SessionID, turnID: UUID) {
        guard var session = sessions[sessionID], session.currentTurnID == turnID else { return }
        mapStructuredLine(line, sessionID: sessionID, session: &session)
        sessions[sessionID] = session
    }

    private func emitStderrLine(_ line: String, sessionID: SessionID, turnID: UUID) {
        guard var session = sessions[sessionID], session.currentTurnID == turnID else { return }
        emit(
            AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: Date.unixMillisecondsNow,
                confidence: .unknown,
                payload: .rawOutput(RawOutput(text: line, reason: "Claude stderr"))
            ),
            to: &session
        )
        sessions[sessionID] = session
    }

    private func mapStructuredLine(_ line: String, sessionID: SessionID, session: inout ClaudeSession) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let type = root["type"] as? String else {
            emit(
                AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: Date.unixMillisecondsNow,
                    confidence: .unknown,
                    payload: .rawOutput(RawOutput(text: line, reason: "unparsed Claude stream-json line"))
                ),
                to: &session
            )
            return
        }

        switch type {
        case "stream_event":
            guard
                let event = root["event"] as? [String: Any],
                let delta = event["delta"] as? [String: Any],
                let deltaType = delta["type"] as? String,
                deltaType == "text_delta",
                let text = delta["text"] as? String,
                !text.isEmpty
            else {
                return
            }
            emit(
                AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: Date.unixMillisecondsNow,
                    confidence: .versionedStream,
                    payload: .messageText(MessageText(role: .agent, text: text))
                ),
                to: &session
            )
        case "result":
            let isError = root["is_error"] as? Bool ?? false
            let summary = (root["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorText = (root["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if isError {
                emit(
                    AgentEvent(
                        sessionID: sessionID,
                        agent: identifier,
                        sequence: 0,
                        timestamp: Date.unixMillisecondsNow,
                        confidence: .versionedStream,
                        payload: .failed(AgentErrorInfo(
                            code: "claude.result",
                            message: errorText.flatMap { $0.isEmpty ? nil : $0 }
                                ?? summary.flatMap { $0.isEmpty ? nil : $0 }
                                ?? "Claude turn failed",
                            recovery: .retry
                        ))
                    ),
                    to: &session
                )
            } else {
                emit(
                    AgentEvent(
                        sessionID: sessionID,
                        agent: identifier,
                        sequence: 0,
                        timestamp: Date.unixMillisecondsNow,
                        confidence: .versionedStream,
                        payload: .completed(CompletionResult(
                            succeeded: true,
                            summary: summary.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude turn completed"
                        ))
                    ),
                    to: &session
                )
            }
            session.turnEmittedTerminalEvent = true
            session.turnMode = nil
            session.currentProcess = nil
        default:
            break
        }
    }

    private func structuredTurnDidExit(sessionID: SessionID, turnID: UUID, turnDirectory: URL, status: Int32) {
        guard var session = sessions[sessionID] else { return }
        guard session.currentTurnID == turnID else {
            cleanupHookDirectory(turnDirectory)
            try? FileManager.default.removeItem(at: turnDirectory)
            return
        }
        session.currentProcess = nil
        session.turnMode = nil
        session.pendingApprovals.removeAll()
        session.currentTurnID = nil
        session.currentTurnDirectory = nil
        cleanupHookDirectory(turnDirectory)
        try? FileManager.default.removeItem(at: turnDirectory)
        if !session.turnEmittedTerminalEvent {
            let payload: AgentEventPayload = status == 0
                ? .completed(CompletionResult(succeeded: true, summary: "Claude turn completed"))
                : .failed(AgentErrorInfo(code: "claude.exit", message: "Claude exited with status \(status)", recovery: .retry))
            emit(
                AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: Date.unixMillisecondsNow,
                    confidence: .unknown,
                    payload: payload
                ),
                to: &session
            )
        }
        sessions[sessionID] = session
    }

    private func handlePTYOutput(sessionID: SessionID, turnID: UUID, data: Data) {
        guard var session = sessions[sessionID], session.currentTurnID == turnID else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        emit(
            AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: Date.unixMillisecondsNow,
                confidence: .ptyHeuristic,
                payload: .rawOutput(RawOutput(text: text, reason: "Claude PTY fallback"))
            ),
            to: &session
        )
        sessions[sessionID] = session
    }

    private func handlePTYExit(sessionID: SessionID, turnID: UUID, turnDirectory: URL, status: Int32) {
        guard var session = sessions[sessionID] else { return }
        guard session.currentTurnID == turnID else {
            cleanupHookDirectory(turnDirectory)
            try? FileManager.default.removeItem(at: turnDirectory)
            return
        }
        session.turnMode = nil
        session.currentTurnID = nil
        session.currentTurnDirectory = nil
        cleanupHookDirectory(turnDirectory)
        try? FileManager.default.removeItem(at: turnDirectory)
        let payload: AgentEventPayload = status == 0
            ? .completed(CompletionResult(succeeded: true, summary: "Claude PTY turn completed"))
            : .failed(AgentErrorInfo(code: "claude.pty", message: "Claude PTY exited with status \(status)", recovery: .retry))
        emit(
            AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: Date.unixMillisecondsNow,
                confidence: .ptyHeuristic,
                payload: payload
            ),
            to: &session
        )
        sessions[sessionID] = session
    }

    private func pollHookRequests(sessionID: SessionID) {
        guard var session = sessions[sessionID], let turnDirectory = session.currentTurnDirectory else { return }
        let requestURLs = (try? FileManager.default.contentsOfDirectory(
            at: turnDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in requestURLs where url.lastPathComponent.hasPrefix("request-") && url.pathExtension == "json" {
            let name = url.lastPathComponent
            guard !session.seenRequestFiles.contains(name) else { continue }
            session.seenRequestFiles.insert(name)
            if let request = try? parseApprovalRequest(from: url, session: session) {
                session.pendingApprovals[request.id] = turnDirectory
                    .appendingPathComponent("response-\(request.id.wireString).json")
                emit(
                    AgentEvent(
                        sessionID: sessionID,
                        agent: identifier,
                        sequence: 0,
                        timestamp: request.createdAt,
                        confidence: .native,
                        payload: .approvalRequested(request)
                    ),
                    to: &session
                )
            }
        }
        sessions[sessionID] = session
    }

    private func parseApprovalRequest(from url: URL, session: ClaudeSession) throws -> ApprovalRequest {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let requestText = root["request_id"] as? String,
              let requestID = ApprovalRequestID(requestText) else {
            throw ClaudeAdapterError.launchFailed("Malformed Claude hook request")
        }

        let toolName = root["tool_name"] as? String ?? "unknown"
        let toolInput = root["tool_input"]
        let originalPayload = foundationJSONToJSONValue(root)
        // .native (1.0) is approval-eligible by construction; guard instead
        // of force-unwrapping so a future threshold change fails honestly.
        guard let confidence = ApprovalEligibleConfidence(.native) else {
            throw ClaudeAdapterError.launchFailed("native confidence must be approval-eligible")
        }
        return ApprovalRequest(
            id: requestID,
            agent: identifier,
            projectID: session.projectID,
            sessionID: session.handle.sessionID,
            tool: toolName,
            exactAction: exactAction(toolName: toolName, toolInput: toolInput),
            explanation: "Claude wants to run \(toolName).",
            files: filePaths(from: toolInput),
            domains: [],
            workingDirectory: root["cwd"] as? String ?? session.workingDirectory,
            risk: .medium,
            reversibility: .unknown,
            originalProviderPayload: originalPayload,
            confidence: confidence,
            createdAt: Date.unixMillisecondsNow
        )
    }

    private func exactAction(toolName: String, toolInput: Any?) -> String {
        guard let toolInput else { return toolName }
        if let object = toolInput as? [String: Any] {
            if let command = object["command"] as? String, !command.isEmpty {
                return command
            }
            if let filePath = object["file_path"] as? String, !filePath.isEmpty {
                return filePath
            }
            if let paths = object["paths"] as? [String], !paths.isEmpty {
                return paths.joined(separator: ", ")
            }
        }
        if let json = jsonString(for: toolInput), !json.isEmpty {
            return "\(toolName) \(json)"
        }
        return toolName
    }

    private func filePaths(from toolInput: Any?) -> [String] {
        guard let object = toolInput as? [String: Any] else { return [] }
        if let filePath = object["file_path"] as? String, !filePath.isEmpty {
            return [filePath]
        }
        if let oldPath = object["old_file_path"] as? String,
           let newPath = object["new_file_path"] as? String,
           !oldPath.isEmpty, !newPath.isEmpty {
            return [oldPath, newPath]
        }
        if let paths = object["paths"] as? [String] {
            return paths
        }
        return []
    }

    private func foundationJSONToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let integer = number.int64Value
            if NSNumber(value: integer) == number {
                return .int(integer)
            }
            return .string(number.stringValue)
        case let array as [Any]:
            return .array(array.map(foundationJSONToJSONValue))
        case let object as [String: Any]:
            return .object(object.mapValues(foundationJSONToJSONValue))
        default:
            return .string(String(describing: value))
        }
    }

    private func jsonString(for value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func cleanupHookDirectory(_ directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func emit(_ event: AgentEvent, to session: inout ClaudeSession) {
        session.continuation?.yield(event)
    }

    private func mergedEnvironment() -> [String: String] {
        AgentEnvironment.sanitizedForAgent(
            additionalPrefixes: Self.environmentPrefixes,
            overrides: environmentOverrides
        )
    }

    /// Version probe with a hard 5 s timeout: a hung `claude` binary must
    /// surface as a broken installation, not block inspection forever.
    private static func runVersion(executablePath: String) throws -> String {
        let output = try BoundedProcessRunner.run(
            executable: executablePath,
            arguments: ["--version"],
            timeoutSeconds: 5
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
