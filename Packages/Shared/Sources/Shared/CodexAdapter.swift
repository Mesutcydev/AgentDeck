//
//  CodexAdapter.swift
//  Shared — AgentDeck
//
//  §11.1 Codex app-server adapter. Maps JSON-RPC notifications to shared
//  AgentEvent models (confidence 1.0 native). Uncertain provider output
//  degrades to rawOutput (§10.4).
//

import Foundation

#if os(macOS)

public actor CodexAdapter: AgentAdapter {
    public let identifier: AgentIdentifier
    public let capabilities: AgentCapabilities
    public nonisolated let externalSessionCapabilities = ExternalSessionCapabilities(
        discovery: .supported,
        importing: .supported
    )

    private let executablePath: String
    private var sessions: [SessionID: CodexSession] = [:]
    private var pendingApprovalRPCs: [ApprovalRequestID: Int64] = [:]

    private struct CodexSession {
        let handle: AgentSessionHandle
        let client: CodexAppServerClient
        let threadID: String
        let projectID: ProjectID
        let workingDirectory: String
        var continuation: AsyncStream<AgentEvent>.Continuation?
    }

    public init(identifier: AgentIdentifier, executablePath: String) {
        self.identifier = identifier
        self.executablePath = executablePath
        self.capabilities = AgentCapabilities(
            structuredEvents: true,
            approvals: true,
            sessionResume: true,
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

        let client = CodexAppServerClient(configuration: .init(
            executablePath: executablePath,
            workingDirectory: configuration.workingDirectory
        ))

        var eventContinuation: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }

        try client.start()
        _ = try await client.call(method: "initialize", params: .object([
            ("clientInfo", .object([("name", .string("AgentDeck")), ("version", .string("1.0"))]))
        ]))

        let threadID: String
        if let imported = configuration.providerSessionReference {
            threadID = imported.externalSessionID
            _ = try await client.call(
                method: "thread/resume",
                params: .object([("threadId", .string(threadID))])
            )
        } else {
            let threadResult = try await client.call(
                method: "thread/start",
                params: .object([("cwd", .string(configuration.workingDirectory))])
            )
            guard let startedThreadID = threadResult.optionalField("threadId")?.stringValue
                ?? threadResult.optionalField("thread")?.optionalField("id")?.stringValue else {
                throw CodexAppServerError.protocolError("missing threadId")
            }
            threadID = startedThreadID
        }

        client.setNotificationHandler { method, params in
            Task { await self.handleNotification(
                sessionID: sessionID,
                method: method,
                params: params
            ) }
        }
        client.setRequestHandler { id, method, params in
            Task { await self.handleServerRequest(
                sessionID: sessionID,
                requestID: id,
                method: method,
                params: params
            ) }
        }

        sessions[sessionID] = CodexSession(
            handle: handle,
            client: client,
            threadID: threadID,
            projectID: configuration.projectID,
            workingDirectory: configuration.workingDirectory,
            continuation: eventContinuation
        )

        if let prompt = configuration.initialPrompt {
            try await sendTurn(prompt: prompt, sessionID: sessionID, threadID: threadID, client: client)
        }

        return AgentSessionStream(handle: handle, events: events)
    }

    public func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {
        guard let codex = sessions[session.sessionID] else { return }
        switch input {
        case .prompt(let prompt):
            try await sendTurn(
                prompt: prompt,
                sessionID: session.sessionID,
                threadID: codex.threadID,
                client: codex.client
            )
        }
    }

    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {
        guard let codex = sessions[session.sessionID] else { return }
        if let rpcID = pendingApprovalRPCs.removeValue(forKey: requestID) {
            let response = decision.choice.authorizes ? "accept" : "decline"
            try codex.client.respond(
                id: rpcID,
                result: .object([("decision", .string(response))])
            )
        } else {
            // Compatibility with older app-server fixtures and releases.
            _ = try await codex.client.call(
                method: "approval/respond",
                params: .object([
                    ("requestId", .string(requestID.wireString)),
                    ("decision", .string(decision.choice.authorizes ? "approved" : "denied"))
                ])
            )
        }
    }

    public func interrupt(session: AgentSessionHandle) async throws {
        guard let codex = sessions[session.sessionID] else { return }
        _ = try await codex.client.call(
            method: "turn/cancel",
            params: .object([("threadId", .string(codex.threadID))])
        )
    }

    public func resume(session: AgentSessionHandle) async throws {
        guard let codex = sessions[session.sessionID] else { return }
        _ = try await codex.client.call(
            method: "thread/resume",
            params: .object([("threadId", .string(codex.threadID))])
        )
    }

    public func terminate(session: AgentSessionHandle) async throws {
        guard let codex = sessions.removeValue(forKey: session.sessionID) else { return }
        codex.continuation?.finish()
        codex.client.stop()
    }

    private func handleNotification(sessionID: SessionID, method: String, params: JSONValue) {
        guard let codex = sessions[sessionID],
              let continuation = codex.continuation,
              let event = mapNotification(
                method: method,
                params: params,
                sessionID: sessionID,
                projectID: codex.projectID,
                workingDirectory: codex.workingDirectory
              ) else { return }
        continuation.yield(event)
    }

    private func eventContinuation(for sessionID: SessionID) -> AsyncStream<AgentEvent>.Continuation? {
        sessions[sessionID]?.continuation
    }

    private func handleServerRequest(
        sessionID: SessionID,
        requestID: Int64,
        method: String,
        params: JSONValue
    ) {
        guard let codex = sessions[sessionID], let continuation = codex.continuation else { return }
        guard method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval" else {
            try? codex.client.respond(
                id: requestID,
                result: .object([("decision", .string("decline"))])
            )
            return
        }

        let approvalID = ApprovalRequestID.random()
        pendingApprovalRPCs[approvalID] = requestID
        let isCommand = method == "item/commandExecution/requestApproval"
        let command = params.optionalField("command")?.stringValue
        let reason = params.optionalField("reason")?.stringValue
        let action = command ?? reason ?? (isCommand ? "Run a command" : "Apply file changes")
        guard let confidence = ApprovalEligibleConfidence(.native) else { return }
        let request = ApprovalRequest(
            id: approvalID,
            agent: identifier,
            projectID: codex.projectID,
            sessionID: sessionID,
            tool: isCommand ? "shell" : "file change",
            exactAction: action,
            explanation: reason ?? action,
            workingDirectory: params.optionalField("cwd")?.stringValue ?? codex.workingDirectory,
            risk: .medium,
            reversibility: .unknown,
            originalProviderPayload: params,
            confidence: confidence,
            createdAt: Date.unixMillisecondsNow
        )
        continuation.yield(AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: request.createdAt,
            confidence: .native,
            payload: .approvalRequested(request)
        ))
    }

    private func sendTurn(
        prompt: PromptInput,
        sessionID: SessionID,
        threadID: String,
        client: CodexAppServerClient
    ) async throws {
        _ = try await client.call(
            method: "turn/start",
            params: .object([
                ("threadId", .string(threadID)),
                ("input", .array([.object([
                    ("type", .string("text")),
                    ("text", .string(prompt.text))
                ])]))
            ])
        )
    }

    private func mapNotification(
        method: String,
        params: JSONValue,
        sessionID: SessionID,
        projectID: ProjectID,
        workingDirectory: String
    ) -> AgentEvent? {
        let now = Date.unixMillisecondsNow
        switch method {
        case "turn/agentMessageDelta", "item/agentMessage/delta":
            guard let delta = params.optionalField("delta")?.stringValue ?? params.stringValue else {
                return uncertainRaw(params, sessionID: sessionID, reason: "unparsed agent delta")
            }
            return AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: now,
                confidence: .native,
                payload: .messageText(MessageText(role: .agent, text: delta))
            )
        case "approval/request":
            return mapApproval(params, sessionID: sessionID, projectID: projectID, workingDirectory: workingDirectory)
        case "turn/completed":
            let success = (try? params.boolField("success")) ?? true
            return AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: now,
                confidence: .native,
                payload: .completed(CompletionResult(succeeded: success, summary: "turn completed"))
            )
        default:
            return uncertainRaw(params, sessionID: sessionID, reason: "unknown notification \(method)")
        }
    }

    private func mapApproval(
        _ params: JSONValue,
        sessionID: SessionID,
        projectID: ProjectID,
        workingDirectory: String
    ) -> AgentEvent? {
        guard
            let requestText = try? params.stringField("requestId"),
            let requestID = ApprovalRequestID(requestText),
            let tool = try? params.stringField("tool"),
            let action = try? params.stringField("action"),
            let explanation = try? params.stringField("explanation"),
            let confidence = ApprovalEligibleConfidence(.native)
        else {
            return uncertainRaw(params, sessionID: sessionID, reason: "malformed approval request")
        }
        let request = ApprovalRequest(
            id: requestID,
            agent: identifier,
            projectID: projectID,
            sessionID: sessionID,
            tool: tool,
            exactAction: action,
            explanation: explanation,
            workingDirectory: workingDirectory,
            risk: .medium,
            reversibility: .unknown,
            originalProviderPayload: params,
            confidence: confidence,
            createdAt: Date.unixMillisecondsNow
        )
        return AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: request.createdAt,
            confidence: .native,
            payload: .approvalRequested(request)
        )
    }

    private func uncertainRaw(
        _ params: JSONValue,
        sessionID: SessionID,
        reason: String
    ) -> AgentEvent {
        AgentEvent(
            sessionID: sessionID,
            agent: identifier,
            sequence: 0,
            timestamp: Date.unixMillisecondsNow,
            confidence: .unknown,
            payload: .rawOutput(RawOutput(text: params.canonicalString(), reason: reason))
        )
    }
}

#endif
