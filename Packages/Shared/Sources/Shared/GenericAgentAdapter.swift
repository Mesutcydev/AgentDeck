//
//  GenericAgentAdapter.swift
//  Shared — AgentDeck
//
//  §11.1 #6 generic user-defined agent — defaults to terminal (PTY) mode.
//

import Foundation

#if os(macOS)

public struct GenericAgentConfiguration: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

public enum GenericAgentAdapterError: Error, Equatable {
    case sessionNotFound(SessionID)
}

/// User-defined agent that runs in raw terminal mode (§11.1 #6).
public actor GenericAgentAdapter: AgentAdapter {
    public let identifier: AgentIdentifier
    public let capabilities: AgentCapabilities

    private let configuration: GenericAgentConfiguration
    private let ptySupervisor: PTYSupervisor
    private var sessions: [SessionID: GenericSession] = [:]

    private struct GenericSession {
        let handle: AgentSessionHandle
        let projectID: ProjectID
        let workingDirectory: String
        var continuation: AsyncStream<AgentEvent>.Continuation?
        var outputSink: AsyncStream<Data>.Continuation?
        var outputPumpTask: Task<Void, Never>?
    }

    public init(
        identifier: AgentIdentifier,
        configuration: GenericAgentConfiguration,
        ptySupervisor: PTYSupervisor = PTYSupervisor()
    ) {
        self.identifier = identifier
        self.configuration = configuration
        self.ptySupervisor = ptySupervisor
        self.capabilities = AgentCapabilities(
            structuredEvents: false,
            approvals: false,
            sessionResume: false,
            cancellation: true,
            streaming: true
        )
    }

    public func inspectInstallation() async -> AgentInstallation {
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            return AgentInstallation(state: .notInstalled, executablePath: nil)
        }
        return AgentInstallation(
            state: .installed(version: "generic"),
            executablePath: configuration.executablePath
        )
    }

    public func inspectAuthentication() async -> AgentAuthenticationState {
        .unknown
    }

    public func launch(configuration launchConfig: AgentLaunchConfiguration) async throws -> AgentSessionStream {
        let sessionID = launchConfig.sessionID
        let handle = AgentSessionHandle(sessionID: sessionID, agent: identifier)

        var eventContinuation: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }

        // Serialized output path: PTY chunks are yielded into one stream
        // consumed by a single pump task — no per-chunk fire-and-forget.
        let (outputStream, outputSink) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let outputPumpTask = Task { [weak self] in
            for await data in outputStream {
                await self?.emitRawOutput(data, sessionID: sessionID)
            }
        }

        sessions[sessionID] = GenericSession(
            handle: handle,
            projectID: launchConfig.projectID,
            workingDirectory: launchConfig.workingDirectory,
            continuation: eventContinuation,
            outputSink: outputSink,
            outputPumpTask: outputPumpTask
        )

        // User-defined agents: the operator's explicit environment entries
        // are the only additions beyond the sanitized base allowlist.
        let env = AgentEnvironment.sanitizedForAgent(overrides: configuration.environment)

        do {
            _ = try await ptySupervisor.launch(
                PTYLaunchRequest(
                    sessionID: sessionID,
                    executable: configuration.executablePath,
                    arguments: configuration.arguments,
                    environment: env,
                    workingDirectory: launchConfig.workingDirectory
                ),
                outputHandler: { data in
                    outputSink.yield(data)
                }
            )
        } catch {
            outputPumpTask.cancel()
            outputSink.finish()
            sessions.removeValue(forKey: sessionID)
            eventContinuation?.finish()
            throw error
        }

        eventContinuation?.yield(AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: Date.unixMillisecondsNow,
            confidence: .ptyHeuristic,
            payload: .stateChanged(SessionStateChange(from: .starting, to: .runningCommand))
        ))

        if let prompt = launchConfig.initialPrompt {
            try await send(.prompt(prompt), to: handle)
        }

        return AgentSessionStream(handle: handle, events: events)
    }

    public func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {
        guard case .prompt(let prompt) = input else { return }
        let data = Data((prompt.text + "\n").utf8)
        try await ptySupervisor.sendInput(sessionID: session.sessionID, data: data)
    }

    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {}

    public func interrupt(session: AgentSessionHandle) async throws {
        await ptySupervisor.terminate(sessionID: session.sessionID)
    }

    public func resume(session: AgentSessionHandle) async throws {}

    public func terminate(session: AgentSessionHandle) async throws {
        await ptySupervisor.terminate(sessionID: session.sessionID)
        sessions[session.sessionID]?.outputPumpTask?.cancel()
        sessions[session.sessionID]?.outputSink?.finish()
        sessions[session.sessionID]?.continuation?.finish()
        sessions.removeValue(forKey: session.sessionID)
    }

    private func emitRawOutput(_ data: Data, sessionID: SessionID) {
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              let continuation = sessions[sessionID]?.continuation else {
            return
        }
        continuation.yield(AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: Date.unixMillisecondsNow,
            confidence: .ptyHeuristic,
            payload: .rawOutput(RawOutput(text: text, reason: "generic terminal output"))
        ))
    }
}

#endif
