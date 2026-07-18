//
//  GrokAdapter.swift
//  Shared — AgentDeck
//
//  §11.1 #3 Grok adapter. Attempts structured headless JSON when available;
//  degrades to PTY raw terminal per ADR-0005 when ACP wire is incompatible.
//

import Foundation

#if os(macOS)

public enum GrokAdapterError: Error, Equatable {
    case sessionNotFound(SessionID)
    case launchFailed(String)
}

public actor GrokAdapter: AgentAdapter {
    public let identifier: AgentIdentifier
    public let capabilities: AgentCapabilities

    private let executablePath: String
    private let ptySupervisor: PTYSupervisor
    private let forcePTYFallback: Bool
    private var sessions: [SessionID: GrokSession] = [:]

    private enum Mode {
        case structured
        case pty
    }

    /// Documented environment additions for Grok only: xAI credentials and
    /// Grok CLI config. Everything else is stripped by the allowlist.
    private static let environmentPrefixes = ["XAI_", "GROK_"]

    private struct GrokSession {
        let handle: AgentSessionHandle
        let projectID: ProjectID
        let workingDirectory: String
        var continuation: AsyncStream<AgentEvent>.Continuation?
        var mode: Mode
        var process: Process?
        var stdinHandle: FileHandle?
        var stdoutBuffer = BoundedLineBuffer()
        var outputSink: AsyncStream<Data>.Continuation?
        var outputPumpTask: Task<Void, Never>?
    }

    public init(
        identifier: AgentIdentifier,
        executablePath: String,
        forcePTYFallback: Bool = false,
        ptySupervisor: PTYSupervisor = PTYSupervisor()
    ) {
        self.identifier = identifier
        self.executablePath = executablePath
        self.forcePTYFallback = forcePTYFallback
        self.ptySupervisor = ptySupervisor
        self.capabilities = AgentCapabilities(
            structuredEvents: !forcePTYFallback,
            approvals: false,
            sessionResume: false,
            cancellation: true,
            streaming: true
        )
    }

    public func inspectInstallation() async -> AgentInstallation {
        await CLIInstallationProbe.inspect(executablePath: executablePath)
    }

    public func inspectAuthentication() async -> AgentAuthenticationState {
        .authenticated
    }

    public func launch(configuration: AgentLaunchConfiguration) async throws -> AgentSessionStream {
        let sessionID = configuration.sessionID
        let handle = AgentSessionHandle(sessionID: sessionID, agent: identifier)

        var eventContinuation: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }

        let mode: Mode = forcePTYFallback ? .pty : .structured
        sessions[sessionID] = GrokSession(
            handle: handle,
            projectID: configuration.projectID,
            workingDirectory: configuration.workingDirectory,
            continuation: eventContinuation,
            mode: mode
        )

        switch mode {
        case .pty:
            try await launchPTY(sessionID: sessionID, configuration: configuration)
        case .structured:
            do {
                try await launchStructured(sessionID: sessionID, configuration: configuration)
            } catch {
                sessions[sessionID]?.mode = .pty
                try await launchPTY(sessionID: sessionID, configuration: configuration)
            }
        }

        if let prompt = configuration.initialPrompt {
            try await send(.prompt(prompt), to: handle)
        }

        return AgentSessionStream(handle: handle, events: events)
    }

    public func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {
        guard case .prompt(let prompt) = input,
              let grok = sessions[session.sessionID] else { return }
        switch grok.mode {
        case .pty:
            try await ptySupervisor.sendInput(
                sessionID: session.sessionID,
                data: Data((prompt.text + "\n").utf8)
            )
        case .structured:
            guard let handle = grok.stdinHandle else { return }
            let line = prompt.text + "\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {}

    public func interrupt(session: AgentSessionHandle) async throws {
        guard let grok = sessions[session.sessionID] else {
            throw GrokAdapterError.sessionNotFound(session.sessionID)
        }
        switch grok.mode {
        case .pty:
            await ptySupervisor.terminate(sessionID: session.sessionID)
        case .structured:
            if let process = grok.process {
                ProcessGroupTerminator.terminateTree(process: process)
            }
        }
    }

    public func resume(session: AgentSessionHandle) async throws {}

    public func terminate(session: AgentSessionHandle) async throws {
        guard let grok = sessions.removeValue(forKey: session.sessionID) else { return }
        if let process = grok.process {
            ProcessGroupTerminator.terminateTree(process: process)
        }
        await ptySupervisor.terminate(sessionID: session.sessionID)
        grok.outputPumpTask?.cancel()
        grok.outputSink?.finish()
        grok.continuation?.finish()
    }

    private func launchPTY(sessionID: SessionID, configuration: AgentLaunchConfiguration) async throws {
        let (outputStream, outputSink) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let pumpTask = Task { [weak self] in
            for await data in outputStream {
                await self?.emitRaw(data, sessionID: sessionID, confidence: .ptyHeuristic)
            }
        }
        do {
            _ = try await ptySupervisor.launch(
                PTYLaunchRequest(
                    sessionID: sessionID,
                    executable: executablePath,
                    arguments: [],
                    environment: AgentEnvironment.sanitizedForAgent(
                        additionalPrefixes: Self.environmentPrefixes
                    ),
                    workingDirectory: configuration.workingDirectory
                ),
                outputHandler: { data in
                    outputSink.yield(data)
                }
            )
        } catch {
            pumpTask.cancel()
            outputSink.finish()
            throw error
        }
        sessions[sessionID]?.outputSink = outputSink
        sessions[sessionID]?.outputPumpTask = pumpTask
        sessions[sessionID]?.continuation?.yield(AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: Date.unixMillisecondsNow,
            confidence: .ptyHeuristic,
            payload: .stateChanged(SessionStateChange(from: .starting, to: .runningCommand))
        ))
    }

    private func launchStructured(sessionID: SessionID, configuration: AgentLaunchConfiguration) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--output-format", "stream-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = AgentEnvironment.sanitizedForAgent(
            additionalPrefixes: Self.environmentPrefixes
        )

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice

        // Serialized output path: stdout chunks funnel into one stream
        // consumed by a single pump task — no per-chunk fire-and-forget.
        let (outputStream, outputSink) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let pumpTask = Task { [weak self] in
            for await data in outputStream {
                await self?.consumeStructured(data, sessionID: sessionID)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                outputSink.finish()
            } else {
                outputSink.yield(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            pumpTask.cancel()
            outputSink.finish()
            throw error
        }
        ProcessGroupTerminator.makeGroupLeader(processIdentifier: process.processIdentifier)
        sessions[sessionID]?.process = process
        sessions[sessionID]?.stdinHandle = stdinPipe.fileHandleForWriting
        sessions[sessionID]?.outputSink = outputSink
        sessions[sessionID]?.outputPumpTask = pumpTask
    }

    private func consumeStructured(_ chunk: Data, sessionID: SessionID) {
        guard !chunk.isEmpty, var grok = sessions[sessionID] else { return }
        for line in grok.stdoutBuffer.append(chunk) {
            guard let json = try? JSONParser.parse(line),
                  let event = mapStructuredLine(json, sessionID: sessionID),
                  let continuation = grok.continuation else { continue }
            continuation.yield(event)
        }
        sessions[sessionID] = grok
    }

    private func mapStructuredLine(_ json: JSONValue, sessionID: SessionID) -> AgentEvent? {
        let now = Date.unixMillisecondsNow
        if let type = json.optionalField("type")?.stringValue {
            switch type {
            case "assistant", "message":
                let text = json.optionalField("content")?.stringValue
                    ?? json.optionalField("text")?.stringValue ?? ""
                guard !text.isEmpty else { return nil }
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .versionedStream,
                    payload: .messageText(MessageText(role: .agent, text: text))
                )
            case "result", "completed":
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .versionedStream,
                    payload: .completed(CompletionResult(succeeded: true, summary: "grok turn completed"))
                )
            default:
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .unknown,
                    payload: .rawOutput(RawOutput(text: json.canonicalString(), reason: "unparsed grok event"))
                )
            }
        }
        return nil
    }

    private func emitRaw(_ data: Data, sessionID: SessionID, confidence: EventConfidence) {
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              let continuation = sessions[sessionID]?.continuation else { return }
        continuation.yield(AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: Date.unixMillisecondsNow,
            confidence: confidence,
            payload: .rawOutput(RawOutput(text: text, reason: "grok terminal output"))
        ))
    }
}

#endif
