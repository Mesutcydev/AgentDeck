import Foundation
import Testing
@testable import Shared

@Suite("Session event mirror")
struct SessionEventMirrorTests {
    @Test("mirrors timeline events and approval requests")
    func mirrorEvents() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let mirror = SessionEventMirror(repository: store)
        let sessionID = SessionID.random()
        let agent = try #require(AgentIdentifier("com.example.agent"))

        let message = AgentEvent(
            sessionID: sessionID,
            agent: agent,
            sequence: 1,
            timestamp: 100,
            confidence: .native,
            payload: .messageText(MessageText(role: .agent, text: "hello"))
        )
        try await mirror.mirror(message)

        let events = try await store.events(sessionID: sessionID, afterSequence: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events[0].sequence == 1)

        let session = try await store.session(id: sessionID)
        #expect(session?.agent == agent)

        let request = ApprovalRequest(
            id: .random(),
            agent: agent,
            projectID: .random(),
            sessionID: sessionID,
            tool: "shell",
            exactAction: "git status",
            explanation: "Check status",
            files: [],
            domains: [],
            workingDirectory: "/tmp",
            risk: .low,
            reversibility: .reversible,
            originalProviderPayload: .object([("demo", .bool(true))]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: 200
        )
        let approvalEvent = AgentEvent(
            sessionID: sessionID,
            agent: agent,
            sequence: 2,
            timestamp: 200,
            confidence: .native,
            payload: .approvalRequested(request)
        )
        try await mirror.mirror(approvalEvent)

        let pending = try await store.pendingApprovals(limit: 10)
        #expect(pending.count == 1)
        #expect(try await store.session(id: sessionID)?.state == .waitingForApproval)
    }

    @Test("duplicate sequences are ignored")
    func duplicateSequence() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let mirror = SessionEventMirror(repository: store)
        let sessionID = SessionID.random()
        let agent = try #require(AgentIdentifier("com.example.agent"))
        let event = AgentEvent(
            sessionID: sessionID,
            agent: agent,
            sequence: 1,
            timestamp: 1,
            confidence: .native,
            payload: .rawOutput(RawOutput(text: "x", reason: "test"))
        )
        try await mirror.mirror(event)
        try await mirror.mirror(event)
        let events = try await store.events(sessionID: sessionID, afterSequence: nil, limit: 10)
        #expect(events.count == 1)
    }
}
