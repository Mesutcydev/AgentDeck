//
//  AgentSessionOrchestratorTests.swift
//  SharedTests — AgentDeck
//
//  §29 Phase 6 orchestration hardening: policy-before-idempotency ordering
//  (no resolution poisoning), §16/§20.2 working-directory containment at
//  time of use, the §12.4 structured-session cap, the per-session
//  persisted-event cap with honest gap markers, and approval TTL expiry
//  (terminal, recorded, audited, broadcast).
//

import Foundation
import Synchronization
import Testing
@testable import Shared

#if os(macOS)

private actor BroadcastCollector {
    private(set) var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }

    func count(ofKind kind: String) -> Int {
        events.filter { $0.payload.kind == kind }.count
    }
}

/// A controllable §10.1 stub: emits canned events at launch and records
/// approval decisions delivered to the provider. Shared by the
/// orchestration and session-serving suites.
final class SessionStubAdapter: AgentAdapter, @unchecked Sendable {
    let identifier: AgentIdentifier
    let capabilities = AgentCapabilities(
        structuredEvents: true,
        approvals: true,
        sessionResume: false,
        cancellation: true,
        streaming: true
    )

    private let launchEvents: [AgentEvent]
    private let deliveredDecisions = Mutex<[ApprovalChoice]>([])

    init(identifier: AgentIdentifier, launchEvents: [AgentEvent] = []) {
        self.identifier = identifier
        self.launchEvents = launchEvents
    }

    var decisions: [ApprovalChoice] { deliveredDecisions.withLock { $0 } }

    func inspectInstallation() async -> AgentInstallation {
        AgentInstallation(state: .installed(version: "1.0"))
    }

    func inspectAuthentication() async -> AgentAuthenticationState { .authenticated }

    func launch(configuration: AgentLaunchConfiguration) async throws -> AgentSessionStream {
        let handle = AgentSessionHandle(sessionID: configuration.sessionID, agent: identifier)
        let events = launchEvents
        return AgentSessionStream(
            handle: handle,
            events: AsyncStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        )
    }

    func send(_ input: AgentInput, to session: AgentSessionHandle) async throws {}

    func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws {
        deliveredDecisions.withLock { $0.append(decision.choice) }
    }

    func interrupt(session: AgentSessionHandle) async throws {}
    func resume(session: AgentSessionHandle) async throws {}
    func terminate(session: AgentSessionHandle) async throws {}
}

@Suite("§29 session orchestration hardening")
struct AgentSessionOrchestratorTests {
    private let now: Int64 = 1_752_793_200_000

    private func makeAgentID() throws -> AgentIdentifier {
        try #require(AgentIdentifier("com.example.adapter"))
    }

    private func makeProject(in store: SQLiteSessionStore) async throws -> (ProjectID, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = try PathSafety.canonicalPath(for: directory)
        let project = ProjectRecord(
            id: .random(),
            displayName: "Fixture Project",
            canonicalPath: canonical,
            createdAt: now
        )
        try await store.insertProject(project)
        return (project.id, canonical)
    }

    @Test("unsupported adapters reject external imports with a typed result")
    func unsupportedExternalImport() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let (projectID, path) = try await makeProject(in: store)
        let agentID = try makeAgentID()
        let orchestrator = AgentSessionOrchestrator(repository: store)
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let reference = ProviderSessionReference(
            providerID: agentID,
            externalSessionID: "provider-session",
            importedAt: now
        )

        await #expect(throws: AgentSessionOrchestratorError.externalImportUnsupported(agentID, .notImplemented)) {
            _ = try await orchestrator.startSession(
                agent: agentID,
                configuration: AgentLaunchConfiguration(
                    projectID: projectID,
                    workingDirectory: path,
                    origin: .externalImport,
                    providerSessionReference: reference
                )
            )
        }
    }

    private func makeRequest(
        sessionID: SessionID,
        projectID: ProjectID,
        agent: AgentIdentifier,
        action: String = "make test",
        risk: RiskClassification = .low,
        createdAt: Int64,
        expiresAt: Int64? = nil
    ) throws -> ApprovalRequest {
        ApprovalRequest(
            id: .random(),
            agent: agent,
            projectID: projectID,
            sessionID: sessionID,
            tool: "shell",
            exactAction: action,
            explanation: "Orchestrator test request",
            workingDirectory: "/tmp",
            risk: risk,
            reversibility: .unknown,
            originalProviderPayload: .object([:]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @Test("starting a session broadcasts its stateChanged so peers learn the sessionID")
    func startBroadcastsSessionID() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let collector = BroadcastCollector()
        let orchestrator = AgentSessionOrchestrator(
            repository: store,
            broadcast: { event in await collector.record(event) },
            nowProvider: { [now] in now }
        )
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, root) = try await makeProject(in: store)

        let sessionID = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )
        let firstEvent = try #require(await collector.events.first)
        #expect(firstEvent.sessionID == sessionID)
        guard case .stateChanged(let change) = firstEvent.payload else {
            Issue.record("expected a stateChanged start event, got \(firstEvent.payload.kind)")
            return
        }
        #expect(change.from == .starting)
        #expect(change.to == .thinking)
        #expect(try await store.session(id: sessionID) != nil)
    }

    @Test("policy validation precedes the idempotency slot: a rejected decision never poisons the request")
    func resolutionNotPoisoned() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let orchestrator = AgentSessionOrchestrator(repository: store, nowProvider: { [now] in now })
        let agentID = try makeAgentID()
        let adapter = SessionStubAdapter(identifier: agentID)
        await orchestrator.registerAdapter(adapter)
        let (projectID, root) = try await makeProject(in: store)
        let sessionID = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )

        // Critical action: secure confirmation is mandatory (§15.4).
        let request = try makeRequest(
            sessionID: sessionID,
            projectID: projectID,
            agent: agentID,
            action: "sudo rm  -rf /tmp/cache",
            risk: .critical,
            createdAt: now
        )
        try await orchestrator.registerApproval(request)

        let allow = try ApprovalDecision(choice: .allowOnce, decidedAt: now + 1_000)
        await #expect(throws: ApprovalPolicyError.criticalApprovalRequiresSecureConfirmation) {
            _ = try await orchestrator.resolveApproval(
                requestID: request.id,
                decision: allow,
                sessionID: sessionID,
                usedSecureConfirmation: false
            )
        }

        // The rejected attempt must NOT have consumed the §9 slot: the
        // corrected decision still applies as the FIRST resolution.
        let corrected = try await orchestrator.resolveApproval(
            requestID: request.id,
            decision: allow,
            sessionID: sessionID,
            usedSecureConfirmation: true
        )
        #expect(!corrected.wasAlreadyResolved, "a policy-rejected attempt must not record a resolution")
        #expect(corrected.decision.choice == .allowOnce)

        // §9 idempotency from here on: retries replay the original outcome.
        let deny = try ApprovalDecision(choice: .deny, decidedAt: now + 2_000)
        let retry = try await orchestrator.resolveApproval(
            requestID: request.id,
            decision: deny,
            sessionID: sessionID,
            usedSecureConfirmation: true
        )
        #expect(retry.wasAlreadyResolved)
        #expect(retry.decision.choice == .allowOnce)
        #expect(adapter.decisions == [.allowOnce], "the provider saw exactly one delivered decision")
    }

    @Test("workingDirectory outside the authorized project root is rejected at time of use")
    func containmentEnforced() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let orchestrator = AgentSessionOrchestrator(repository: store, nowProvider: { [now] in now })
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, _) = try await makeProject(in: store)

        await #expect(throws: PathSafetyError.self) {
            _ = try await orchestrator.startSession(
                agent: agentID,
                configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: "/etc")
            )
        }
        #expect(try await store.listSessions().isEmpty, "no session record persists on rejection")
    }

    @Test("the structured-session cap rejects overflow with a typed resource-limit error")
    func sessionCap() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let orchestrator = AgentSessionOrchestrator(repository: store, maxConcurrentSessions: 2, nowProvider: { [now] in now })
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, root) = try await makeProject(in: store)

        let first = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )
        _ = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )
        await #expect(throws: AgentSessionOrchestratorError.sessionLimitReached(limit: 2)) {
            _ = try await orchestrator.startSession(
                agent: agentID,
                configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
            )
        }

        // Terminating frees a slot.
        try await orchestrator.terminate(sessionID: first)
        _ = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )
    }

    @Test("the session cap clamps to the §12.4 range like PTYSupervisor")
    func sessionCapClamping() async throws {
        let store = try SQLiteSessionStore.inMemory()
        // 0 clamps to 1: a single live session fills the cap.
        let orchestrator = AgentSessionOrchestrator(repository: store, maxConcurrentSessions: 0, nowProvider: { [now] in now })
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, root) = try await makeProject(in: store)
        _ = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )
        await #expect(throws: AgentSessionOrchestratorError.sessionLimitReached(limit: 1)) {
            _ = try await orchestrator.startSession(
                agent: agentID,
                configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
            )
        }
    }

    @Test("events past the per-session cap drop with ONE explicit gap marker")
    func eventFloodGapMarker() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let collector = BroadcastCollector()
        let orchestrator = AgentSessionOrchestrator(
            repository: store,
            broadcast: { event in await collector.record(event) },
            maximumPersistedEventsPerSession: 3,
            nowProvider: { [now] in now }
        )
        let agentID = try makeAgentID()
        let flood = (0..<5).map { index in
            AgentEvent(
                sessionID: .random(),
                agent: agentID,
                sequence: 0,
                timestamp: Int64(index),
                confidence: .native,
                payload: .rawOutput(RawOutput(text: "flood \(index)", reason: "test"))
            )
        }
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID, launchEvents: flood))
        let (projectID, root) = try await makeProject(in: store)
        let sessionID = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )

        // Cap 3: stateChanged + 2 rawOutputs persist; the 3rd rawOutput
        // trips the cap → one transport gap marker; the rest drop.
        let settled = await waitForCondition {
            let stored = (try? await store.events(sessionID: sessionID, afterSequence: nil, limit: 100)) ?? []
            return stored.count == 4
        }
        #expect(settled, "store should settle at 3 events + 1 gap marker")
        let stored = try await store.events(sessionID: sessionID, afterSequence: nil, limit: 100)
        #expect(stored.filter { $0.kind == "rawOutput" }.count == 2)
        #expect(stored.filter { $0.kind == "stateChanged" }.count == 1)
        let markers = stored.filter { $0.kind == "transport" }
        #expect(markers.count == 1, "exactly one honest gap marker")
        let markerPayload = try #require(markers.first?.payload)
        let notice = try TransportNotice(jsonValue: markerPayload)
        #expect(notice.code == .eventGap)

        // Live broadcast continues (transient stream), so listeners saw all
        // five raw outputs plus the marker.
        let broadcastSettled = await waitForCondition {
            let rawCount = await collector.count(ofKind: "rawOutput")
            let transportCount = await collector.count(ofKind: "transport")
            return rawCount == 5 && transportCount == 1
        }
        #expect(broadcastSettled)
    }

    @Test("a stale approval expires terminally: recorded, audited, broadcast — later decisions rejected")
    func expiryOnRegistration() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let collector = BroadcastCollector()
        let orchestrator = AgentSessionOrchestrator(
            repository: store,
            broadcast: { event in await collector.record(event) },
            nowProvider: { [now] in now }
        )
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, root) = try await makeProject(in: store)
        let sessionID = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )

        let stale = try makeRequest(
            sessionID: sessionID,
            projectID: projectID,
            agent: agentID,
            createdAt: now - 600_000 // 10 min old; TTL is 5
        )
        try await orchestrator.registerApproval(stale)

        // Recorded in the §12.5 store as decided (deny artifact).
        let approvals = try await store.approvals(sessionID: sessionID)
        #expect(approvals.first?.decision?.choice == .deny)
        #expect(approvals.first?.isPending == false)
        // Audited honestly.
        let audit = try await store.approvalAuditEntries(sessionID: sessionID, limit: 20)
        #expect(audit.contains { $0.eventKind == .requestExpired })
        // Broadcast as an expired resolution so devices render the truth.
        let broadcastSettled = await waitForCondition {
            await collector.events.contains {
                if case .approvalResolved(let resolution) = $0.payload {
                    return resolution.expired && resolution.requestID == stale.id
                }
                return false
            }
        }
        #expect(broadcastSettled, "the expiry must be broadcast as expired")

        await #expect(throws: ApprovalError.requestExpired(stale.id)) {
            _ = try await orchestrator.resolveApproval(
                requestID: stale.id,
                decision: try ApprovalDecision(choice: .allowOnce, decidedAt: self.now),
                sessionID: sessionID,
                usedSecureConfirmation: true
            )
        }
    }

    @Test("the sweep expires overdue pending requests exactly once")
    func expirySweep() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let clock = Mutex(now)
        let orchestrator = AgentSessionOrchestrator(
            repository: store,
            nowProvider: { clock.withLock { $0 } }
        )
        let agentID = try makeAgentID()
        await orchestrator.registerAdapter(SessionStubAdapter(identifier: agentID))
        let (projectID, root) = try await makeProject(in: store)
        let sessionID = try await orchestrator.startSession(
            agent: agentID,
            configuration: AgentLaunchConfiguration(projectID: projectID, workingDirectory: root)
        )

        let request = try makeRequest(
            sessionID: sessionID,
            projectID: projectID,
            agent: agentID,
            createdAt: now,
            expiresAt: now + 60_000
        )
        try await orchestrator.registerApproval(request)
        #expect(try await store.approvals(sessionID: sessionID).first?.isPending == true)

        // Before the deadline the sweep leaves it pending.
        try await orchestrator.sweepExpiredApprovals(now: now + 59_000)
        #expect(try await store.approvals(sessionID: sessionID).first?.isPending == true)

        // Past the deadline it expires — once.
        try await orchestrator.sweepExpiredApprovals(now: now + 61_000)
        #expect(try await store.approvals(sessionID: sessionID).first?.decision?.choice == .deny)
        try await orchestrator.sweepExpiredApprovals(now: now + 62_000)
        let audit = try await store.approvalAuditEntries(sessionID: sessionID, limit: 20)
        #expect(audit.filter { $0.eventKind == .requestExpired }.count == 1,
                "the terminal expiry is recorded exactly once")
    }
}

#endif
