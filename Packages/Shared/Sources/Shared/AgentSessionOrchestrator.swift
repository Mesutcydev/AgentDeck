//
//  AgentSessionOrchestrator.swift
//  Shared — AgentDeck
//
//  §29 Phase 6 Mac-side session orchestration: adapter lifecycle, event
//  persistence, live broadcast to paired devices, interim approval resolve.
//
//  Hardening (§15/§16/§20):
//   - workingDirectory is re-validated against the authorized project root
//     with PathSafety AT TIME OF USE (containment, symlink escapes).
//   - Concurrent sessions are capped (same §12.4 default 4, clamp 1–8 as
//     PTYSupervisor) with a typed resource-limit error.
//   - Policy validation runs BEFORE the §9 idempotency slot is consumed,
//     so a rejected decision never poisons a request.
//   - Approval TTL: expired requests resolve to a terminal expired state
//     (recorded + audited + broadcast); later decisions are rejected.
//   - Persisted events are capped per session; overflow is dropped with an
//     explicit transport gap marker (honest degradation, Constitution #2).
//

import Foundation

#if os(macOS)

public enum AgentSessionOrchestratorError: Error, Equatable {
    case sessionNotFound(SessionID)
    case adapterNotRegistered(AgentIdentifier)
    case projectNotAuthorized(ProjectID)
    /// §12.4 structured-session cap (same shape as the PTY supervisor's).
    case sessionLimitReached(limit: Int)
}

/// Persists agent events and broadcasts them to live peer connections.
public actor AgentSessionOrchestrator {
    public typealias BroadcastHandler = @Sendable (AgentEvent) async throws -> Void
    public typealias NotificationDispatchHandler = @Sendable (AgentEvent) async -> Void

    /// §12.4 structured-session cap bounds (mirrors PTYSupervisor).
    public static let defaultMaxConcurrentSessions = 4
    public static let maxConcurrentSessionsRange = 1...8
    /// Default per-session persisted-event cap (output-flood bound, §20).
    public static let defaultMaximumPersistedEventsPerSession = 10_000

    private let repository: any SessionRepository
    private let broadcast: BroadcastHandler?
    private let notificationDispatch: NotificationDispatchHandler?
    private let policyEngine: ApprovalPolicyEngine
    private let maxConcurrentSessions: Int
    private let maximumPersistedEventsPerSession: Int
    private let nowProvider: @Sendable () -> Int64
    private let approvalDefaultTTLMilliseconds: Int64
    private var adapters: [AgentIdentifier: any AgentAdapter] = [:]
    private var activeSessions: [SessionID: ActiveSession] = [:]
    private var sequenceBySession: [SessionID: UInt64] = [:]
    private var persistedEventsBySession: [SessionID: Int] = [:]
    private var droppedEventsBySession: [SessionID: Int64] = [:]
    private let approvalResolver: ApprovalResolver

    private struct ActiveSession: Sendable {
        let handle: AgentSessionHandle
        let adapter: AgentIdentifier
        let projectID: ProjectID
        var state: SessionActivityState
        var consumeTask: Task<Void, Never>?
        var providerThreadID: String?
    }

    public init(
        repository: any SessionRepository,
        broadcast: BroadcastHandler? = nil,
        notificationDispatch: NotificationDispatchHandler? = nil,
        maxConcurrentSessions: Int = AgentSessionOrchestrator.defaultMaxConcurrentSessions,
        maximumPersistedEventsPerSession: Int = AgentSessionOrchestrator.defaultMaximumPersistedEventsPerSession,
        approvalDefaultTTLMilliseconds: Int64 = ApprovalRequest.defaultTTLMilliseconds,
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow }
    ) {
        self.repository = repository
        self.broadcast = broadcast
        self.notificationDispatch = notificationDispatch
        self.policyEngine = ApprovalPolicyEngine(repository: repository)
        let clamp = AgentSessionOrchestrator.maxConcurrentSessionsRange
        self.maxConcurrentSessions = min(clamp.upperBound, max(clamp.lowerBound, maxConcurrentSessions))
        self.maximumPersistedEventsPerSession = max(1, maximumPersistedEventsPerSession)
        self.approvalDefaultTTLMilliseconds = approvalDefaultTTLMilliseconds
        self.nowProvider = nowProvider
        self.approvalResolver = ApprovalResolver(
            nowProvider: nowProvider,
            defaultTTLMilliseconds: approvalDefaultTTLMilliseconds
        )
    }

    public func registerAdapter(_ adapter: any AgentAdapter) {
        adapters[adapter.identifier] = adapter
    }

    /// Starts a Codex (or other) session with an optional initial prompt.
    public func startSession(
        agent: AgentIdentifier,
        configuration: AgentLaunchConfiguration
    ) async throws -> SessionID {
        guard let adapter = adapters[agent] else {
            throw AgentSessionOrchestratorError.adapterNotRegistered(agent)
        }
        guard let project = try await repository.project(id: configuration.projectID) else {
            throw AgentSessionOrchestratorError.projectNotAuthorized(configuration.projectID)
        }

        // §12.4 concurrent-session cap — enforced BEFORE any launch work.
        let liveCount = activeSessions.values.filter { !$0.state.isTerminal }.count
        guard liveCount < maxConcurrentSessions else {
            throw AgentSessionOrchestratorError.sessionLimitReached(limit: maxConcurrentSessions)
        }

        // §16/§20.2: prove containment inside the authorized project root
        // at time of use — never trust a caller-supplied path verbatim.
        let workingDirectory = try PathSafety.validateProjectPath(
            root: project.canonicalPath,
            candidate: configuration.workingDirectory
        )

        let now = nowProvider()
        let sessionID = SessionID.random()
        let launchConfig = AgentLaunchConfiguration(
            sessionID: sessionID,
            projectID: configuration.projectID,
            workingDirectory: workingDirectory,
            initialPrompt: configuration.initialPrompt,
            model: configuration.model
        )
        let record = SessionRecord(
            id: sessionID,
            agent: agent,
            projectID: configuration.projectID,
            state: .starting,
            createdAt: now,
            updatedAt: now
        )
        try await repository.insertSession(record)

        let stream = try await adapter.launch(configuration: launchConfig)
        var active = ActiveSession(
            handle: stream.handle,
            adapter: agent,
            projectID: configuration.projectID,
            state: .starting,
            consumeTask: nil,
            providerThreadID: nil
        )

        let consumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream.events {
                await self.ingest(event: event, sessionID: sessionID, agent: agent)
            }
        }
        active.consumeTask = consumeTask
        activeSessions[sessionID] = active
        sequenceBySession[sessionID] = 0
        persistedEventsBySession[sessionID] = 0

        try await recordState(sessionID: sessionID, state: .thinking)
        // Broadcast the start honestly so connected peers learn the new
        // sessionID immediately (the session.start flow depends on it).
        let startedEvent = AgentEvent(
            sessionID: sessionID,
            agent: agent,
            sequence: try await nextSequence(for: sessionID),
            timestamp: now,
            confidence: .native,
            payload: .stateChanged(SessionStateChange(from: .starting, to: .thinking))
        )
        try await persistAndBroadcast(startedEvent)
        return sessionID
    }

    public func sendPrompt(_ prompt: PromptInput, sessionID: SessionID) async throws {
        guard let active = activeSessions[sessionID],
              let adapter = adapters[active.adapter] else {
            throw AgentSessionOrchestratorError.sessionNotFound(sessionID)
        }
        try await adapter.send(.prompt(prompt), to: active.handle)
    }

    public func interrupt(sessionID: SessionID) async throws {
        guard let active = activeSessions[sessionID],
              let adapter = adapters[active.adapter] else {
            throw AgentSessionOrchestratorError.sessionNotFound(sessionID)
        }
        try await adapter.interrupt(session: active.handle)
    }

    /// §9 idempotent approval resolve from iOS; Phase 6 interim scope: deny / allowOnce only.
    ///
    /// Ordering is security-critical: policy validation (including
    /// `criticalApprovalRequiresSecureConfirmation`) runs BEFORE the §9
    /// idempotency slot is consumed, so a rejected decision is never
    /// recorded against the request. Expired requests are rejected.
    public func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        sessionID: SessionID,
        usedSecureConfirmation: Bool = false
    ) async throws -> ApprovalResolution {
        guard let request = await approvalResolver.request(for: requestID) else {
            throw ApprovalError.unknownRequest(requestID)
        }
        // Already resolved? Return the original outcome — no slot is
        // consumed and no policy work re-runs (§9). Expired-terminal is a
        // rejection, not an outcome a caller may reuse.
        if let existing = await approvalResolver.resolution(for: requestID) {
            if existing.expired {
                throw ApprovalError.requestExpired(requestID)
            }
            return ApprovalResolution(
                requestID: requestID,
                decision: existing.decision,
                wasAlreadyResolved: true
            )
        }

        let now = nowProvider()
        // TTL gate: fall into the terminal expired state instead of
        // accepting a late decision.
        if try await approvalResolver.expireIfNeeded(requestID: requestID, now: now),
           let resolution = await approvalResolver.resolution(for: requestID) {
            try await recordExpiry(request: request, resolution: resolution, now: now)
            throw ApprovalError.requestExpired(requestID)
        }

        // Policy FIRST — a throw here must leave the request resolvable.
        _ = try await policyEngine.recordManualResolution(
            request: request,
            decision: decision,
            usedSecureConfirmation: usedSecureConfirmation
        )

        // Only now consume the idempotency slot.
        let resolution = try await approvalResolver.resolve(
            requestID: requestID,
            decision: decision,
            now: now
        )
        guard !resolution.wasAlreadyResolved else { return resolution }

        try await repository.recordApprovalDecision(
            requestID: requestID,
            decision: decision,
            resolvedAt: decision.decidedAt
        )

        guard let active = activeSessions[sessionID],
              let adapter = adapters[active.adapter] else {
            throw AgentSessionOrchestratorError.sessionNotFound(sessionID)
        }
        try await adapter.resolveApproval(
            requestID: requestID,
            decision: decision,
            in: active.handle
        )

        let resolvedEvent = AgentEvent(
            sessionID: sessionID,
            agent: active.adapter,
            sequence: try await nextSequence(for: sessionID),
            timestamp: decision.decidedAt,
            confidence: .native,
            payload: .approvalResolved(resolution)
        )
        try await persistAndBroadcast(resolvedEvent)
        try await recordState(sessionID: sessionID, state: .thinking)
        return resolution
    }

    public func registerApproval(_ request: ApprovalRequest) async throws {
        try await approvalResolver.register(request)
        try await repository.insertApproval(ApprovalRecord(request: request))
        let event = AgentEvent(
            sessionID: request.sessionID,
            agent: request.agent,
            sequence: try await nextSequence(for: request.sessionID),
            timestamp: request.createdAt,
            confidence: .native,
            payload: .approvalRequested(request)
        )
        try await persistAndBroadcast(event)

        // TTL gate: a request that arrives already stale expires honestly
        // instead of surfacing on approval cards.
        let now = nowProvider()
        if try await approvalResolver.expireIfNeeded(requestID: request.id, now: now),
           let resolution = await approvalResolver.resolution(for: request.id) {
            try await recordExpiry(request: request, resolution: resolution, now: now)
            return
        }

        let evaluation = try await policyEngine.evaluate(request)
        switch evaluation {
        case .manual:
            try await recordState(sessionID: request.sessionID, state: .waitingForApproval)
        case .autoApproved(let decision, _, _):
            let resolution = try await approvalResolver.resolve(requestID: request.id, decision: decision, now: now)
            try await repository.recordApprovalDecision(
                requestID: request.id,
                decision: decision,
                resolvedAt: decision.decidedAt
            )
            guard let active = activeSessions[request.sessionID],
                  let adapter = adapters[active.adapter] else {
                throw AgentSessionOrchestratorError.sessionNotFound(request.sessionID)
            }
            try await adapter.resolveApproval(
                requestID: request.id,
                decision: decision,
                in: active.handle
            )
            let resolvedEvent = AgentEvent(
                sessionID: request.sessionID,
                agent: request.agent,
                sequence: try await nextSequence(for: request.sessionID),
                timestamp: decision.decidedAt,
                confidence: .native,
                payload: .approvalResolved(resolution)
            )
            try await persistAndBroadcast(resolvedEvent)
            try await recordState(sessionID: request.sessionID, state: .thinking)
        }
    }

    /// Sweeps pending approvals past their TTL into the terminal expired
    /// state: recorded in the §12.5 store, audited, and broadcast so every
    /// device sees the honest expiry. Call periodically (UI/timer).
    public func sweepExpiredApprovals(now: Int64? = nil) async throws {
        let now = now ?? nowProvider()
        let expired = try await approvalResolver.sweepExpired(now: now)
        for resolution in expired {
            guard let request = await approvalResolver.request(for: resolution.requestID) else {
                continue
            }
            try await recordExpiry(request: request, resolution: resolution, now: now)
        }
    }

    /// Persists + audits + broadcasts one terminal expiry (§15.3 TTL).
    private func recordExpiry(
        request: ApprovalRequest,
        resolution: ApprovalResolution,
        now: Int64
    ) async throws {
        // Best-effort store recording: a prior decision row (should not
        // exist for a fresh expiry) must not crash the sweep.
        try? await repository.recordApprovalDecision(
            requestID: request.id,
            decision: resolution.decision,
            resolvedAt: now
        )
        try await policyEngine.recordExpiry(request: request, at: now)
        guard activeSessions[request.sessionID] != nil else { return }
        let event = AgentEvent(
            sessionID: request.sessionID,
            agent: request.agent,
            sequence: try await nextSequence(for: request.sessionID),
            timestamp: now,
            confidence: .native,
            payload: .approvalResolved(resolution)
        )
        try await persistAndBroadcast(event)
        try await recordState(sessionID: request.sessionID, state: .thinking)
    }

    public func terminate(sessionID: SessionID) async throws {
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw AgentSessionOrchestratorError.sessionNotFound(sessionID)
        }
        active.consumeTask?.cancel()
        if let adapter = adapters[active.adapter] {
            try? await adapter.terminate(session: active.handle)
        }
        sequenceBySession[sessionID] = nil
    }

    private func ingest(event: AgentEvent, sessionID: SessionID, agent: AgentIdentifier) async {
        let sequenced = AgentEvent(
            id: event.id,
            sessionID: sessionID,
            agent: agent,
            sequence: (try? await nextSequence(for: sessionID)) ?? event.sequence,
            timestamp: event.timestamp,
            confidence: event.confidence,
            payload: event.payload
        )
        do {
            if case .approvalRequested(let request) = sequenced.payload {
                try await registerApproval(request)
                try await recordState(sessionID: sessionID, state: .waitingForApproval)
                return
            }
            try await persistAndBroadcast(sequenced)
            switch sequenced.payload {
            case .completed:
                try await recordState(sessionID: sessionID, state: .completed)
            case .failed:
                try await recordState(sessionID: sessionID, state: .failed)
            case .stateChanged(let change):
                try await recordState(sessionID: sessionID, state: change.to)
            default:
                break
            }
        } catch {
            Log.logger(.session).error(
                "session ingest failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func nextSequence(for sessionID: SessionID) async throws -> UInt64 {
        let current = sequenceBySession[sessionID, default: 0] + 1
        sequenceBySession[sessionID] = current
        return current
    }

    private func recordState(sessionID: SessionID, state: SessionActivityState) async throws {
        let now = nowProvider()
        try await repository.updateSessionState(
            id: sessionID,
            state: state,
            updatedAt: now,
            endedAt: state.isTerminal ? now : nil,
            completionSummary: nil
        )
        activeSessions[sessionID]?.state = state
    }

    private func persistAndBroadcast(_ event: AgentEvent) async throws {
        // §20 output-flood bound: past the per-session cap, persistence is
        // dropped (live broadcast continues — the store is the bounded
        // resource) and the first drop persists an explicit gap marker so
        // resume clients see an honestly-declared hole (Constitution #2).
        //
        // Actor re-entrancy: every counter read+write happens BEFORE the
        // first suspension point (insertRecord/broadcast). Claiming the
        // slot after an await would let concurrent ingests read the same
        // stale count and defeat the cap.
        let persisted = persistedEventsBySession[event.sessionID, default: 0]
        if persisted >= maximumPersistedEventsPerSession {
            let dropped = (droppedEventsBySession[event.sessionID, default: 0]) + 1
            droppedEventsBySession[event.sessionID] = dropped
            if dropped == 1 {
                let marker = AgentEvent(
                    sessionID: event.sessionID,
                    agent: event.agent,
                    sequence: try await nextSequence(for: event.sessionID),
                    timestamp: event.timestamp,
                    confidence: .native,
                    payload: .transport(TransportNotice(
                        code: .eventGap,
                        message: "Event persistence cap reached (\(maximumPersistedEventsPerSession)); later events were not stored.",
                        metadata: .object([
                            ("droppedFromSequence", try JSONValue.u64(event.sequence)),
                            ("cap", .int(Int64(maximumPersistedEventsPerSession)))
                        ])
                    ))
                )
                persistedEventsBySession[event.sessionID] = persisted + 1
                try await insertRecord(for: marker)
                if let broadcast {
                    try await broadcast(marker)
                }
            } else {
                Log.logger(.session).warning(
                    "session event dropped from persistence (cap \(self.maximumPersistedEventsPerSession, privacy: .public)); total dropped \(dropped, privacy: .public)"
                )
            }
            // Live delivery continues for the triggering event.
            if let broadcast {
                try await broadcast(event)
            }
            if let notificationDispatch {
                await notificationDispatch(event)
            }
            return
        }
        persistedEventsBySession[event.sessionID] = persisted + 1
        try await insertRecord(for: event)
        if let broadcast {
            try await broadcast(event)
        }
        if let notificationDispatch {
            await notificationDispatch(event)
        }
    }

    private func insertRecord(for event: AgentEvent) async throws {
        let record = EventRecord(
            id: event.id,
            sessionID: event.sessionID,
            sequence: event.sequence,
            timestamp: event.timestamp,
            confidence: event.confidence,
            kind: event.payload.kind,
            payload: event.payload.toJSONValue()
        )
        try await repository.insertEvent(record)
    }
}

#endif
