//
//  SessionStoreTests.swift
//  SharedTests — AgentDeck
//
//  §12.5 session database tests: create, migrate (v0→v1), CRUD for every
//  entity, cursor-ordered event pagination, approval-decision conflict,
//  redaction-on-write (no secrets survive), vacuum.
//

import Foundation
import Testing
@testable import Shared

@Suite("§12.5 session database (SQLite)")
struct SessionStoreTests {
    private let now: Int64 = 1_752_793_200_000

    private func makeStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore.inMemory()
    }

    private func makeSession(
        state: SessionActivityState = .thinking,
        project: ProjectID? = nil
    ) throws -> SessionRecord {
        SessionRecord(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: project,
            state: state,
            agentResumeIdentifier: "resume-token-42",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Create & migrate

    @Test("opening an empty database migrates v0 → current and records it")
    func migrateFromEmpty() async throws {
        let store = try makeStore()
        #expect(try await store.schemaVersion() == SQLiteSessionStore.currentSchemaVersion)
        // All schema tables accept rows (proved by the CRUD tests below).
        #expect(try await store.listSessions().isEmpty)
    }

    @Test("reopening a migrated database applies no further migrations")
    func reopenIsStable() async throws {
        let path = NSTemporaryDirectory() + "/agentdeck-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try SQLiteSessionStore(path: path)
        #expect(try await first.schemaVersion() == SQLiteSessionStore.currentSchemaVersion)
        let session = try makeSession()
        try await first.insertSession(session)
        // Reopen: data survives, version stable (§12.5: upgrades never lose history).
        let second = try SQLiteSessionStore(path: path)
        #expect(try await second.schemaVersion() == SQLiteSessionStore.currentSchemaVersion)
        #expect(try await second.session(id: session.id) == session)
    }

    @Test("session origin and opaque provider resume reference survive migration and reopen")
    func sessionOriginRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "/agentdeck-origin-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let provider = try #require(AgentIdentifier("com.anthropic.claude-code"))
        let record = SessionRecord(
            id: .random(), agent: provider, state: .thinking,
            origin: .externalImport,
            providerSessionReference: ProviderSessionReference(
                providerID: provider, externalSessionID: "provider-session-42",
                compatibilityVersion: "2.1.210", importedAt: now
            ),
            createdAt: now, updatedAt: now
        )
        try await store.insertSession(record)
        let reopened = try SQLiteSessionStore(path: path)
        #expect(try await reopened.session(id: record.id) == record)
    }

    // MARK: - Sessions CRUD

    @Test("insert, fetch, update state, list, active count")
    func sessionCRUD() async throws {
        let store = try makeStore()
        let project = ProjectRecord(
            id: .random(), displayName: "Site", canonicalPath: "/Users/test/site", createdAt: now
        )
        try await store.insertProject(project)

        let active = try makeSession(project: project.id)
        let finished = try makeSession(state: .completed)
        try await store.insertSession(active)
        try await store.insertSession(finished)

        #expect(try await store.session(id: active.id) == active)
        #expect(try await store.listSessions().count == 2)
        #expect(try await store.countActiveSessions() == 1)

        try await store.updateSessionState(
            id: active.id, state: .completed, updatedAt: now + 1000,
            endedAt: now + 1000, completionSummary: "done"
        )
        #expect(try await store.countActiveSessions() == 0)
        let updated = try #require(try await store.session(id: active.id))
        #expect(updated.state == .completed)
        #expect(updated.endedAt == now + 1000)
        #expect(updated.completionSummary == "done")
    }

    // MARK: - Events

    @Test("events insert in order and paginate by cursor")
    func eventPagination() async throws {
        let store = try makeStore()
        let session = try makeSession()
        try await store.insertSession(session)

        for sequence: UInt64 in 1...5 {
            try await store.insertEvent(EventRecord(
                id: .random(),
                sessionID: session.id,
                sequence: sequence,
                timestamp: now + Int64(sequence),
                confidence: .native,
                kind: "messageText",
                payload: .object([("payloadV", .int(1)), ("text", .string("event \(sequence)"))])
            ))
        }

        let all = try await store.events(sessionID: session.id, afterSequence: nil, limit: 10)
        #expect(all.count == 5)
        #expect(all.map(\.sequence) == [1, 2, 3, 4, 5])

        // Cursor resume (§14.1): events strictly after sequence 2.
        let afterTwo = try await store.events(sessionID: session.id, afterSequence: 2, limit: 10)
        #expect(afterTwo.map(\.sequence) == [3, 4, 5])

        let limited = try await store.events(sessionID: session.id, afterSequence: nil, limit: 2)
        #expect(limited.map(\.sequence) == [1, 2])
    }

    @Test("duplicate (session, sequence) is a constraint violation")
    func eventUniqueness() async throws {
        let store = try makeStore()
        let session = try makeSession()
        try await store.insertSession(session)
        func event(_ id: EventID) -> EventRecord {
            EventRecord(id: id, sessionID: session.id, sequence: 1, timestamp: now,
                        confidence: .native, kind: "messageText", payload: .object([:]))
        }
        try await store.insertEvent(event(.random()))
        await #expect(throws: RepositoryError.self) {
            try await store.insertEvent(event(.random()))
        }
    }

    @Test("event payloads are redacted before they reach the database")
    func eventPayloadRedaction() async throws {
        let store = try makeStore()
        let session = try makeSession()
        try await store.insertSession(session)
        try await store.insertEvent(EventRecord(
            id: .random(),
            sessionID: session.id,
            sequence: 1,
            timestamp: now,
            confidence: .versionedStream,
            kind: "messageText",
            payload: .object([
                ("payloadV", .int(1)),
                ("text", .string("calling with Bearer abcdef1234567890 failed")),
                ("api_key", .string("sk-secretvalue123456"))
            ])
        ))
        let stored = try #require(
            try await store.events(sessionID: session.id, afterSequence: nil, limit: 1).first
        )
        let canonical = stored.payload.canonicalString()
        #expect(!canonical.contains("abcdef1234567890"))
        #expect(!canonical.contains("sk-secretvalue123456"))
        #expect(canonical.contains("[REDACTED]"))
    }

    // MARK: - Approvals

    @Test("approval insert, decision persist, double decision conflicts, pending count")
    func approvalFlow() async throws {
        let store = try makeStore()
        let session = try makeSession()
        try await store.insertSession(session)
        let confidence = try #require(ApprovalEligibleConfidence(.native))
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: session.id,
            tool: "shell",
            exactAction: "make test",
            explanation: "Run tests",
            workingDirectory: "/tmp",
            risk: .low,
            reversibility: .reversible,
            originalProviderPayload: .object([:]),
            confidence: confidence,
            createdAt: now
        )
        try await store.insertApproval(ApprovalRecord(request: request))
        #expect(try await store.countPendingApprovals() == 1)
        #expect(try await store.pendingApprovals(limit: 10).map(\.request.id) == [request.id])

        let decision = try ApprovalDecision(choice: .allowOnce, decidedAt: now + 5)
        try await store.recordApprovalDecision(
            requestID: request.id, decision: decision, resolvedAt: now + 5
        )
        #expect(try await store.countPendingApprovals() == 0)

        let stored = try #require(try await store.approvals(sessionID: session.id).first)
        #expect(stored.decision == decision)
        #expect(stored.resolvedAt == now + 5)

        // A second decision must not silently overwrite (§9 idempotency).
        await #expect(throws: RepositoryError.conflict("approval \(request.id) already has a decision or is unknown")) {
            try await store.recordApprovalDecision(
                requestID: request.id, decision: decision, resolvedAt: now + 10
            )
        }
    }

    @Test("approval rules and audit entries persist, query, and revoke")
    func approvalRulesAndAudit() async throws {
        let store = try makeStore()
        let projectID = ProjectID.random()
        let sessionID = SessionID.random()
        let rule = try ApprovalRule(
            choice: .allowCommandPatternInProject,
            projectID: projectID,
            tool: "shell",
            commandPattern: "git diff*",
            explanation: "Allow `git diff*` commands in this project.",
            createdAt: now
        )
        try await store.insertApprovalRule(rule)

        let auditEntry = ApprovalAuditEntry(
            requestID: .random(),
            sessionID: sessionID,
            ruleID: rule.id,
            eventKind: .ruleCreated,
            summary: rule.displayText,
            metadata: .object([("token", .string("Bearer secret-token"))]),
            createdAt: now + 1
        )
        try await store.insertApprovalAuditEntry(auditEntry)

        let rules = try await store.listApprovalRules(projectID: projectID, sessionID: sessionID)
        #expect(rules.map(\.id) == [rule.id])

        let audit = try await store.approvalAuditEntries(sessionID: sessionID, limit: 10)
        #expect(audit.map(\.eventKind) == [.ruleCreated])
        #expect(audit.first?.ruleID == rule.id)
        #expect(audit.first?.metadata.canonicalString().contains("[REDACTED]") == true)

        try await store.revokeApprovalRule(id: rule.id, revokedAt: now + 2)
        let revoked = try await store.listApprovalRules(projectID: projectID, sessionID: sessionID)
        #expect(revoked.first?.revokedAt == now + 2)
    }

    // MARK: - Projects / devices / attachments

    @Test("projects insert, fetch, list, delete")
    func projectCRUD() async throws {
        let store = try makeStore()
        let project = ProjectRecord(
            id: .random(), displayName: "AgentDeck", canonicalPath: "/Users/test/agentdeck", createdAt: now
        )
        try await store.insertProject(project)
        #expect(try await store.project(id: project.id) == project)
        #expect(try await store.listProjects() == [project])
        try await store.deleteProject(id: project.id)
        #expect(try await store.project(id: project.id) == nil)
        #expect(try await store.listProjects().isEmpty)
    }

    @Test("devices insert and list with revocation flag")
    func deviceCRUD() async throws {
        let store = try makeStore()
        let device = DeviceRecord(
            id: .random(), displayName: "iPhone", pairedAt: now, lastSeenAt: now, revoked: false
        )
        try await store.insertDevice(device)
        #expect(try await store.listDevices() == [device])
    }

    @Test("attachments insert, mark deleted, list")
    func attachmentCRUD() async throws {
        let store = try makeStore()
        let session = try makeSession()
        try await store.insertSession(session)
        let attachment = AttachmentRecord(
            id: UUID(), sessionID: session.id, fileName: "screenshot.png",
            byteCount: 2048, mimeType: "image/png", createdAt: now
        )
        try await store.insertAttachment(attachment)
        #expect(try await store.attachments(sessionID: session.id) == [attachment])
        try await store.markAttachmentDeleted(id: attachment.id, deletedAt: now + 10)
        #expect(try await store.attachments(sessionID: session.id).first?.deletedAt == now + 10)
    }

    // MARK: - Maintenance

    @Test("vacuum runs after deletions and the store stays usable")
    func vacuum() async throws {
        let path = NSTemporaryDirectory() + "/agentdeck-vacuum-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try SQLiteSessionStore(path: path)
        let session = try makeSession()
        try await store.insertSession(session)
        for sequence: UInt64 in 1...200 {
            try await store.insertEvent(EventRecord(
                id: .random(), sessionID: session.id, sequence: sequence,
                timestamp: now, confidence: .native, kind: "rawOutput",
                payload: .object([("payloadV", .int(1)), ("text", .string(String(repeating: "x", count: 500)))])
            ))
        }
        // Checkpoint so the data is in the main file, then measure it.
        try await store.checkpoint()
        let sizeWithData = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        #expect(sizeWithData > 100_000, "fixture should hold the 200 fat events")
        // Drop the session (cascades its events), then vacuum.
        #expect(try await store.deleteSession(id: session.id) == 1)
        #expect(try await store.events(sessionID: session.id, afterSequence: nil, limit: 300).isEmpty)
        try await store.vacuum() // must not throw
        // WAL mode: the vacuumed image lands in the journal; checkpoint to
        // observe the compacted main file.
        try await store.checkpoint()
        let sizeAfterVacuum = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        #expect(sizeAfterVacuum < sizeWithData, "vacuum should shrink the database file")
        // Store remains fully usable afterwards.
        let again = try makeSession()
        try await store.insertSession(again)
        #expect(try await store.session(id: again.id) == again)
    }
}
