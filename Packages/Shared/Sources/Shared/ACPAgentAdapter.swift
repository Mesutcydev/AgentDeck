//
//  ACPAgentAdapter.swift
//  Shared — AgentDeck
//
//  Shared Zed-lineage ACP adapter for Kimi and OpenCode (§11.1 #4–5).
//

import Foundation

#if os(macOS)

public enum ACPAgentAdapterError: Error, Equatable {
    case sessionNotFound(SessionID)
    case approvalNotFound(ApprovalRequestID)
}

/// Launch profile for vendor-specific ACP subprocess invocation.
public struct ACPLaunchProfile: Sendable, Equatable {
    public var launchArguments: [String]

    public init(launchArguments: [String]) {
        self.launchArguments = launchArguments
    }

    public static let kimi = ACPLaunchProfile(launchArguments: ["acp"])
    public static let opencode = ACPLaunchProfile(launchArguments: ["acp"])
    public static let grok = ACPLaunchProfile(launchArguments: ["agent", "stdio"])
}

public actor ACPAgentAdapter: AgentAdapter {
    public let identifier: AgentIdentifier
    public let capabilities: AgentCapabilities
    public let launchProfile: ACPLaunchProfile

    private let executablePath: String
    private var sessions: [SessionID: ACPSession] = [:]
    private var pendingPermissionRequests: [ApprovalRequestID: Int64] = [:]

    private struct ACPSession {
        let handle: AgentSessionHandle
        let client: ACPClient
        let acpSessionID: String
        let projectID: ProjectID
        let workingDirectory: String
        var continuation: AsyncStream<AgentEvent>.Continuation?
    }

    public init(
        identifier: AgentIdentifier,
        executablePath: String,
        launchProfile: ACPLaunchProfile,
        capabilities: AgentCapabilities? = nil
    ) {
        self.identifier = identifier
        self.executablePath = executablePath
        self.launchProfile = launchProfile
        self.capabilities = capabilities ?? AgentCapabilities(
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

        let client = ACPClient(configuration: .init(
            executablePath: executablePath,
            launchArguments: launchProfile.launchArguments,
            workingDirectory: configuration.workingDirectory
        ))

        var eventContinuation: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuation = continuation
        }

        try client.start()
        client.setNotificationHandler { [weak self] method, params in
            Task { await self?.handleNotification(sessionID: sessionID, method: method, params: params) }
        }
        client.setRequestHandler { [weak self] id, method, params in
            Task { await self?.handleServerRequest(sessionID: sessionID, requestID: id, method: method, params: params) }
        }

        _ = try await client.initialize()
        let acpSessionID = try await client.sessionNew(cwd: configuration.workingDirectory)

        sessions[sessionID] = ACPSession(
            handle: handle,
            client: client,
            acpSessionID: acpSessionID,
            projectID: configuration.projectID,
            workingDirectory: configuration.workingDirectory,
            continuation: eventContinuation
        )

        if let prompt = configuration.initialPrompt {
            try await sendPrompt(prompt, sessionID: sessionID)
        }

        return AgentSessionStream(handle: handle, events: events)
    }

    public func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {
        guard case .prompt(let prompt) = input else { return }
        try await sendPrompt(prompt, sessionID: session.sessionID)
    }

    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {
        guard let rpcID = pendingPermissionRequests.removeValue(forKey: requestID),
              let acp = sessions[session.sessionID] else {
            throw ACPAgentAdapterError.approvalNotFound(requestID)
        }
        let outcome = decision.choice.authorizes ? "approved" : "denied"
        try acp.client.respond(id: rpcID, result: .object([("outcome", .string(outcome))]))
    }

    public func interrupt(session: AgentSessionHandle) async throws {
        guard let acp = sessions[session.sessionID] else {
            throw ACPAgentAdapterError.sessionNotFound(session.sessionID)
        }
        _ = try await acp.client.call(
            method: "session/cancel",
            params: .object([("sessionId", .string(acp.acpSessionID))])
        )
    }

    public func resume(session: AgentSessionHandle) async throws {
        guard let acp = sessions[session.sessionID] else {
            throw ACPAgentAdapterError.sessionNotFound(session.sessionID)
        }
        _ = try await acp.client.call(
            method: "session/load",
            params: .object([
                ("sessionId", .string(acp.acpSessionID)),
                ("cwd", .string(acp.workingDirectory))
            ])
        )
    }

    public func terminate(session: AgentSessionHandle) async throws {
        guard let acp = sessions.removeValue(forKey: session.sessionID) else { return }
        acp.continuation?.finish()
        acp.client.stop()
    }

    private func sendPrompt(_ prompt: PromptInput, sessionID: SessionID) async throws {
        guard let acp = sessions[sessionID] else {
            throw ACPAgentAdapterError.sessionNotFound(sessionID)
        }
        _ = try await acp.client.call(
            method: "session/prompt",
            params: .object([
                ("sessionId", .string(acp.acpSessionID)),
                ("prompt", .array([.object([
                    ("type", .string("text")),
                    ("text", .string(prompt.text))
                ])]))
            ])
        )
    }

    private func handleNotification(sessionID: SessionID, method: String, params: JSONValue) {
        guard method == "session/update",
              let acp = sessions[sessionID],
              let continuation = acp.continuation,
              let event = mapSessionUpdate(params, sessionID: sessionID, acp: acp) else {
            return
        }
        continuation.yield(event)
    }

    private func handleServerRequest(
        sessionID: SessionID,
        requestID: Int64,
        method: String,
        params: JSONValue
    ) async {
        guard method == "session/request_permission",
              let acp = sessions[sessionID],
              let continuation = acp.continuation else {
            return
        }
        guard let event = mapPermissionRequest(
            params,
            rpcID: requestID,
            sessionID: sessionID,
            projectID: acp.projectID,
            workingDirectory: acp.workingDirectory
        ) else {
            try? acp.client.respond(id: requestID, result: .object([("outcome", .string("denied"))]))
            return
        }
        continuation.yield(event)
    }

    private func mapSessionUpdate(
        _ params: JSONValue,
        sessionID: SessionID,
        acp: ACPSession
    ) -> AgentEvent? {
        let now = Date.unixMillisecondsNow
        let update = params.optionalField("update") ?? params
        if let updateType = update.optionalField("sessionUpdate")?.stringValue
            ?? update.optionalField("updateType")?.stringValue
            ?? update.optionalField("type")?.stringValue {
            switch updateType {
            case "agent_message_chunk", "message_chunk", "text":
                let text = update.optionalField("text")?.stringValue
                    ?? update.optionalField("content")?.stringValue
                    ?? update.optionalField("content")?.optionalField("text")?.stringValue
                    ?? ""
                guard !text.isEmpty else { return nil }
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .native,
                    payload: .messageText(MessageText(role: .agent, text: text))
                )
            case "user_message_chunk":
                guard let text = update.optionalField("content")?.optionalField("text")?.stringValue,
                      !text.isEmpty else { return nil }
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .native,
                    payload: .messageText(MessageText(role: .user, text: text))
                )
            case "agent_thought_chunk", "available_commands_update", "usage_update":
                // Provider metadata is intentionally not presented as chat.
                return nil
            case "turn_completed", "completed":
                return AgentEvent(
                    sessionID: sessionID,
                    agent: identifier,
                    sequence: 0,
                    timestamp: now,
                    confidence: .native,
                    payload: .completed(CompletionResult(succeeded: true, summary: "turn completed"))
                )
            default:
                return uncertainRaw(update, sessionID: sessionID, reason: "unknown session/update \(updateType)")
            }
        }
        if let text = update.optionalField("text")?.stringValue, !text.isEmpty {
            return AgentEvent(
                sessionID: sessionID,
                agent: identifier,
                sequence: 0,
                timestamp: now,
                confidence: .native,
                payload: .messageText(MessageText(role: .agent, text: text))
            )
        }
        return uncertainRaw(params, sessionID: sessionID, reason: "unparsed session/update")
    }

    private func mapPermissionRequest(
        _ params: JSONValue,
        rpcID: Int64,
        sessionID: SessionID,
        projectID: ProjectID,
        workingDirectory: String
    ) -> AgentEvent? {
        let tool = (try? params.stringField("tool")) ?? "tool"
        let action = (try? params.stringField("action"))
            ?? (try? params.stringField("description"))
            ?? "permission requested"
        let explanation = (try? params.stringField("explanation"))
            ?? (try? params.stringField("message"))
            ?? action
        guard let confidence = ApprovalEligibleConfidence(.native) else {
            return uncertainRaw(params, sessionID: sessionID, reason: "malformed permission request")
        }
        let requestID = ApprovalRequestID.random()
        pendingPermissionRequests[requestID] = rpcID
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

public typealias KimiAdapter = ACPAgentAdapter
public typealias OpenCodeAdapter = ACPAgentAdapter

extension ACPAgentAdapter {
    /// Failable factories: identifier literals are validated by
    /// `AgentIdentifier.init?`; a malformed constant must yield nil rather
    /// than crash (callers treat nil as "agent unavailable").
    public static func kimi(executablePath: String) -> ACPAgentAdapter? {
        guard let identifier = AgentIdentifier("com.moonshot.kimi") else { return nil }
        return ACPAgentAdapter(
            identifier: identifier,
            executablePath: executablePath,
            launchProfile: .kimi
        )
    }

    public static func opencode(executablePath: String) -> ACPAgentAdapter? {
        guard let identifier = AgentIdentifier("com.anomaly.opencode") else { return nil }
        return ACPAgentAdapter(
            identifier: identifier,
            executablePath: executablePath,
            launchProfile: .opencode
        )
    }
}

#endif
