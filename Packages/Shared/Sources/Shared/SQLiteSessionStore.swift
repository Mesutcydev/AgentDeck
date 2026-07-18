//
//  SQLiteSessionStore.swift
//  Shared — AgentDeck
//
//  ADR-0002: SQLite via the system SQLite3 C API, behind SessionRepository,
//  as an actor (single writer, §12.5; the companion owns the instance).
//  Schema v1: sessions, events, approvals, projects, devices, attachments,
//  schema_migrations. Migrations are explicit, ordered, and transactional.
//  No raw secrets: JSON payloads pass through Redactor before insert.
//

import Foundation
import SQLite3

public actor SQLiteSessionStore: SessionRepository {
    /// Current schema version this build ships.
    public static let currentSchemaVersion = 6

    private let database: SQLiteDatabase

    /// Opens (creating if needed) the database at `path` and applies any
    /// pending migrations. Use `SQLiteSessionStore.inMemory()` in tests.
    public init(path: String) throws {
        let database = try SQLiteDatabase(path: path)
        self.database = database
        try SQLiteSessionStore.migrate(database)
    }

    private init(database: SQLiteDatabase) throws {
        self.database = database
        try SQLiteSessionStore.migrate(database)
    }

    /// Volatile in-memory store (test support).
    public static func inMemory() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(database: SQLiteDatabase(path: ":memory:"))
    }

    // MARK: - Migrations

    private struct Migration {
        let version: Int
        let name: String
        let statements: [String]
    }

    /// Ordered migrations. Append-only: never edit an applied migration —
    /// add the next version (§12.5 explicit migrations).
    private static let migrations: [Migration] = [
        Migration(version: 1, name: "initial-schema", statements: [
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                agent_identifier TEXT NOT NULL,
                project_id TEXT,
                state TEXT NOT NULL,
                agent_resume_identifier TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                ended_at INTEGER,
                completion_summary TEXT
            )
            """,
            """
            CREATE TABLE events (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                confidence INTEGER NOT NULL,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                UNIQUE (session_id, sequence)
            )
            """,
            """
            CREATE TABLE approvals (
                request_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                request_json TEXT NOT NULL,
                decision_json TEXT,
                resolved_at INTEGER,
                created_at INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                canonical_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                last_opened_at INTEGER
            )
            """,
            """
            CREATE TABLE devices (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                paired_at INTEGER,
                last_seen_at INTEGER,
                revoked INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE attachments (
                id TEXT PRIMARY KEY,
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                file_name TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                mime_type TEXT,
                created_at INTEGER NOT NULL,
                deleted_at INTEGER
            )
            """
        ]),
        Migration(version: 2, name: "device-identity-fields", statements: [
            """
            ALTER TABLE devices ADD COLUMN public_key BLOB
            """,
            """
            ALTER TABLE devices ADD COLUMN tls_public_key_hash TEXT
            """,
            """
            ALTER TABLE devices ADD COLUMN capabilities TEXT NOT NULL DEFAULT ''
            """
        ]),
        Migration(version: 3, name: "project-profile-fields", statements: [
            """
            ALTER TABLE projects ADD COLUMN git_root TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN branch TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN preferred_agent TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN preferred_model TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN default_permission_profile TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN last_session_id TEXT
            """,
            """
            ALTER TABLE projects ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0
            """,
            """
            ALTER TABLE projects ADD COLUMN is_worktree INTEGER NOT NULL DEFAULT 0
            """,
            """
            ALTER TABLE projects ADD COLUMN is_git_repository INTEGER NOT NULL DEFAULT 0
            """,
            """
            ALTER TABLE projects ADD COLUMN authorized_at INTEGER NOT NULL DEFAULT 0
            """
        ]),
        Migration(version: 4, name: "approval-policy-and-audit", statements: [
            """
            CREATE TABLE approval_rules (
                id TEXT PRIMARY KEY,
                choice TEXT NOT NULL,
                project_id TEXT,
                session_id TEXT,
                tool TEXT,
                command_pattern TEXT,
                explanation TEXT NOT NULL,
                created_from_request_id TEXT,
                created_at INTEGER NOT NULL,
                expires_at INTEGER,
                revoked_at INTEGER
            )
            """,
            """
            CREATE INDEX approval_rules_active_idx
            ON approval_rules (project_id, session_id, created_at)
            """,
            """
            CREATE TABLE approval_audit_entries (
                id TEXT PRIMARY KEY,
                request_id TEXT,
                session_id TEXT,
                rule_id TEXT,
                event_kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                metadata_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """,
            """
            CREATE INDEX approval_audit_entries_created_idx
            ON approval_audit_entries (created_at)
            """
        ]),
        Migration(version: 5, name: "device-push-token", statements: [
            """
            ALTER TABLE devices ADD COLUMN push_destination_token TEXT
            """
        ]),
        Migration(version: 6, name: "device-last-endpoint", statements: [
            """
            ALTER TABLE devices ADD COLUMN last_known_endpoint TEXT
            """
        ])
    ]

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at INTEGER NOT NULL
            )
            """)
        let applied = Set(try database.query("SELECT version FROM schema_migrations") { statement in
            Int(sqlite3_column_int64(statement, 0))
        })
        for migration in SQLiteSessionStore.migrations where !applied.contains(migration.version) {
            try database.transaction {
                for statement in migration.statements {
                    try database.execute(statement)
                }
                try database.execute("""
                    INSERT INTO schema_migrations (version, name, applied_at)
                    VALUES (\(migration.version), '\(migration.name)', \(Date.unixMillisecondsNow))
                    """)
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try database.query("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    // MARK: - Sessions

    public func insertSession(_ session: SessionRecord) throws {
        try database.run("""
            INSERT INTO sessions (id, agent_identifier, project_id, state,
                agent_resume_identifier, created_at, updated_at, ended_at, completion_summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(session.id.wireString, to: statement, at: 1)
            bind(session.agent.rawValue, to: statement, at: 2)
            bind(session.projectID?.wireString, to: statement, at: 3)
            bind(session.state.rawValue, to: statement, at: 4)
            bind(session.agentResumeIdentifier, to: statement, at: 5)
            sqlite3_bind_int64(statement, 6, session.createdAt)
            sqlite3_bind_int64(statement, 7, session.updatedAt)
            bind(session.endedAt, to: statement, at: 8)
            bind(session.completionSummary, to: statement, at: 9)
        }
    }

    public func session(id: SessionID) throws -> SessionRecord? {
        try database.query("SELECT * FROM sessions WHERE id = ?1") { statement in
            bind(id.wireString, to: statement, at: 1)
        } map: { statement in
            try sessionRecord(from: statement)
        }.first
    }

    public func updateSessionState(
        id: SessionID,
        state: SessionActivityState,
        updatedAt: Int64,
        endedAt: Int64?,
        completionSummary: String?
    ) throws {
        try database.run("""
            UPDATE sessions SET state = ?, updated_at = ?, ended_at = ?, completion_summary = ?
            WHERE id = ?
            """) { statement in
            bind(state.rawValue, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, updatedAt)
            bind(endedAt, to: statement, at: 3)
            bind(completionSummary, to: statement, at: 4)
            bind(id.wireString, to: statement, at: 5)
        }
    }

    public func listSessions() throws -> [SessionRecord] {
        try database.query("SELECT * FROM sessions ORDER BY created_at") { statement in
            try sessionRecord(from: statement)
        }
    }

    public func deleteSession(id: SessionID) throws -> Int {
        try database.run("DELETE FROM sessions WHERE id = ?") { statement in
            bind(id.wireString, to: statement, at: 1)
        }
    }

    public func countActiveSessions() throws -> Int {
        let terminal = [SessionActivityState.completed, .failed, .interrupted]
            .map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try database.query("SELECT COUNT(*) FROM sessions WHERE state NOT IN (\(terminal))") {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    private nonisolated func sessionRecord(from statement: OpaquePointer) throws -> SessionRecord {
        guard
            let idText = textColumn(statement, 0),
            let id = SessionID(idText),
            let agentText = textColumn(statement, 1),
            let agent = AgentIdentifier(agentText),
            let stateText = textColumn(statement, 3),
            let state = SessionActivityState(rawValue: stateText)
        else {
            throw RepositoryError.statementFailed("malformed sessions row")
        }
        return SessionRecord(
            id: id,
            agent: agent,
            projectID: textColumn(statement, 2).flatMap { ProjectID($0) },
            state: state,
            agentResumeIdentifier: textColumn(statement, 4),
            createdAt: sqlite3_column_int64(statement, 5),
            updatedAt: sqlite3_column_int64(statement, 6),
            endedAt: optionalInt64Column(statement, 7),
            completionSummary: textColumn(statement, 8)
        )
    }

    // MARK: - Events

    public func insertEvent(_ event: EventRecord) throws {
        let sequence = try checkedInt64(event.sequence, field: "event.sequence")
        // Constitution #8: payloads are redacted before they reach the
        // session database.
        let redactedPayload = Redactor.redact(event.payload)
        try database.run("""
            INSERT INTO events (id, session_id, sequence, timestamp, confidence, kind, payload_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(event.id.wireString, to: statement, at: 1)
            bind(event.sessionID.wireString, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, sequence)
            sqlite3_bind_int64(statement, 4, event.timestamp)
            sqlite3_bind_int64(statement, 5, event.confidence.basisPoints)
            bind(event.kind, to: statement, at: 6)
            bind(redactedPayload.canonicalString(), to: statement, at: 7)
        }
    }

    public func events(sessionID: SessionID, afterSequence: UInt64?, limit: Int) throws -> [EventRecord] {
        let after = try checkedInt64(afterSequence ?? 0, field: "afterSequence")
        return try database.query("""
            SELECT * FROM events WHERE session_id = ?1 AND sequence > ?2
            ORDER BY sequence LIMIT ?3
            """) { statement in
            bind(sessionID.wireString, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, after)
            sqlite3_bind_int64(statement, 3, Int64(limit))
        } map: { statement in
            guard
                let idText = textColumn(statement, 0),
                let id = EventID(idText),
                let sessionText = textColumn(statement, 1),
                let rowSessionID = SessionID(sessionText),
                let kind = textColumn(statement, 5),
                let payloadText = textColumn(statement, 6),
                let confidence = EventConfidence(basisPoints: sqlite3_column_int64(statement, 4))
            else {
                throw RepositoryError.statementFailed("malformed events row")
            }
            return EventRecord(
                id: id,
                sessionID: rowSessionID,
                sequence: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                timestamp: sqlite3_column_int64(statement, 3),
                confidence: confidence,
                kind: kind,
                payload: try JSONParser.parse(payloadText)
            )
        }
    }

    // MARK: - Approvals

    public func insertApproval(_ record: ApprovalRecord) throws {
        let redactedRequest = Redactor.redact(record.request.toJSONValue())
        try database.run("""
            INSERT INTO approvals (request_id, session_id, request_json, decision_json, resolved_at, created_at)
            VALUES (?, ?, ?, NULL, NULL, ?)
            """) { statement in
            bind(record.request.id.wireString, to: statement, at: 1)
            bind(record.request.sessionID.wireString, to: statement, at: 2)
            bind(redactedRequest.canonicalString(), to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, record.request.createdAt)
        }
    }

    public func recordApprovalDecision(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        resolvedAt: Int64
    ) throws {
        // UPDATE only while unresolved; a second decision is a conflict,
        // never a silent overwrite (§9 idempotency, data integrity).
        let changed = try database.run("""
            UPDATE approvals SET decision_json = ?, resolved_at = ?
            WHERE request_id = ? AND decision_json IS NULL
            """) { statement in
            bind(decision.toJSONValue().canonicalString(), to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, resolvedAt)
            bind(requestID.wireString, to: statement, at: 3)
        }
        guard changed > 0 else {
            throw RepositoryError.conflict("approval \(requestID) already has a decision or is unknown")
        }
    }

    public func approvals(sessionID: SessionID) throws -> [ApprovalRecord] {
        try database.query("SELECT * FROM approvals WHERE session_id = ?1 ORDER BY created_at") { statement in
            bind(sessionID.wireString, to: statement, at: 1)
        } map: { statement in
            try approvalRecord(from: statement)
        }
    }

    public func pendingApprovals(limit: Int) throws -> [ApprovalRecord] {
        try database.query("""
            SELECT * FROM approvals
            WHERE decision_json IS NULL
            ORDER BY created_at
            LIMIT ?1
            """) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
        } map: { statement in
            try approvalRecord(from: statement)
        }
    }

    public func countPendingApprovals() throws -> Int {
        try database.query("SELECT COUNT(*) FROM approvals WHERE decision_json IS NULL") {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    public func insertApprovalRule(_ rule: ApprovalRule) throws {
        try database.run("""
            INSERT INTO approval_rules (
                id, choice, project_id, session_id, tool, command_pattern,
                explanation, created_from_request_id, created_at, expires_at, revoked_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(rule.id.wireString, to: statement, at: 1)
            bind(rule.choice.rawValue, to: statement, at: 2)
            bind(rule.projectID?.wireString, to: statement, at: 3)
            bind(rule.sessionID?.wireString, to: statement, at: 4)
            bind(rule.tool, to: statement, at: 5)
            bind(rule.commandPattern, to: statement, at: 6)
            bind(rule.explanation, to: statement, at: 7)
            bind(rule.createdFromRequestID?.wireString, to: statement, at: 8)
            sqlite3_bind_int64(statement, 9, rule.createdAt)
            bind(rule.expiresAt, to: statement, at: 10)
            bind(rule.revokedAt, to: statement, at: 11)
        }
    }

    public func listApprovalRules(projectID: ProjectID?, sessionID: SessionID?) throws -> [ApprovalRule] {
        let whereClauses = [
            "(project_id IS NULL OR project_id = ?1)",
            "(session_id IS NULL OR session_id = ?2)"
        ].joined(separator: " AND ")
        return try database.query("""
            SELECT * FROM approval_rules
            WHERE \(whereClauses)
            ORDER BY created_at DESC
            """) { statement in
            bind(projectID?.wireString, to: statement, at: 1)
            bind(sessionID?.wireString, to: statement, at: 2)
        } map: { statement in
            try approvalRule(from: statement)
        }
    }

    public func revokeApprovalRule(id: ApprovalRuleID, revokedAt: Int64) throws {
        let changed = try database.run("""
            UPDATE approval_rules SET revoked_at = ?
            WHERE id = ? AND revoked_at IS NULL
            """) { statement in
            sqlite3_bind_int64(statement, 1, revokedAt)
            bind(id.wireString, to: statement, at: 2)
        }
        guard changed > 0 else {
            throw RepositoryError.notFound
        }
    }

    public func insertApprovalAuditEntry(_ entry: ApprovalAuditEntry) throws {
        let redactedMetadata = Redactor.redact(entry.metadata)
        try database.run("""
            INSERT INTO approval_audit_entries (
                id, request_id, session_id, rule_id, event_kind, summary, metadata_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(entry.id.wireString, to: statement, at: 1)
            bind(entry.requestID?.wireString, to: statement, at: 2)
            bind(entry.sessionID?.wireString, to: statement, at: 3)
            bind(entry.ruleID?.wireString, to: statement, at: 4)
            bind(entry.eventKind.rawValue, to: statement, at: 5)
            bind(entry.summary, to: statement, at: 6)
            bind(redactedMetadata.canonicalString(), to: statement, at: 7)
            sqlite3_bind_int64(statement, 8, entry.createdAt)
        }
    }

    public func approvalAuditEntries(sessionID: SessionID?, limit: Int) throws -> [ApprovalAuditEntry] {
        try database.query("""
            SELECT * FROM approval_audit_entries
            WHERE (?1 IS NULL OR session_id = ?1)
            ORDER BY created_at DESC
            LIMIT ?2
            """) { statement in
            bind(sessionID?.wireString, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        } map: { statement in
            try approvalAuditEntry(from: statement)
        }
    }

    private nonisolated func approvalRecord(from statement: OpaquePointer) throws -> ApprovalRecord {
        guard let requestText = textColumn(statement, 2) else {
            throw RepositoryError.statementFailed("malformed approvals row")
        }
        return ApprovalRecord(
            request: try ApprovalRequest(jsonValue: JSONParser.parse(requestText)),
            decision: try textColumn(statement, 3).map {
                try ApprovalDecision(jsonValue: JSONParser.parse($0))
            },
            resolvedAt: optionalInt64Column(statement, 4)
        )
    }

    private nonisolated func approvalRule(from statement: OpaquePointer) throws -> ApprovalRule {
        guard
            let idText = textColumn(statement, 0),
            let id = ApprovalRuleID(idText),
            let choiceText = textColumn(statement, 1),
            let choice = ApprovalChoice(rawValue: choiceText),
            let explanation = textColumn(statement, 6)
        else {
            throw RepositoryError.statementFailed("malformed approval_rules row")
        }
        return try ApprovalRule(
            id: id,
            choice: choice,
            projectID: textColumn(statement, 2).flatMap { ProjectID($0) },
            sessionID: textColumn(statement, 3).flatMap { SessionID($0) },
            tool: textColumn(statement, 4),
            commandPattern: textColumn(statement, 5),
            explanation: explanation,
            createdFromRequestID: textColumn(statement, 7).flatMap { ApprovalRequestID($0) },
            createdAt: sqlite3_column_int64(statement, 8),
            expiresAt: optionalInt64Column(statement, 9),
            revokedAt: optionalInt64Column(statement, 10)
        )
    }

    private nonisolated func approvalAuditEntry(from statement: OpaquePointer) throws -> ApprovalAuditEntry {
        guard
            let idText = textColumn(statement, 0),
            let id = ApprovalAuditEntryID(idText),
            let eventKindText = textColumn(statement, 4),
            let eventKind = ApprovalAuditEventKind(rawValue: eventKindText),
            let summary = textColumn(statement, 5),
            let metadataText = textColumn(statement, 6)
        else {
            throw RepositoryError.statementFailed("malformed approval_audit_entries row")
        }
        return ApprovalAuditEntry(
            id: id,
            requestID: textColumn(statement, 1).flatMap { ApprovalRequestID($0) },
            sessionID: textColumn(statement, 2).flatMap { SessionID($0) },
            ruleID: textColumn(statement, 3).flatMap { ApprovalRuleID($0) },
            eventKind: eventKind,
            summary: summary,
            metadata: try JSONParser.parse(metadataText),
            createdAt: sqlite3_column_int64(statement, 7)
        )
    }

    // MARK: - Projects

    public func insertProject(_ project: ProjectRecord) throws {
        try database.run("""
            INSERT INTO projects (
                id, display_name, canonical_path, created_at, last_opened_at,
                git_root, branch, preferred_agent, preferred_model,
                default_permission_profile, last_session_id,
                is_favorite, is_worktree, is_git_repository, authorized_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(project.id.wireString, to: statement, at: 1)
            bind(project.displayName, to: statement, at: 2)
            bind(project.canonicalPath, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, project.createdAt)
            bind(project.lastOpenedAt, to: statement, at: 5)
            bind(project.gitRoot, to: statement, at: 6)
            bind(project.branch, to: statement, at: 7)
            bind(project.preferredAgent?.rawValue, to: statement, at: 8)
            bind(project.preferredModel, to: statement, at: 9)
            bind(project.defaultPermissionProfile, to: statement, at: 10)
            bind(project.lastSessionID?.wireString, to: statement, at: 11)
            sqlite3_bind_int64(statement, 12, project.isFavorite ? 1 : 0)
            sqlite3_bind_int64(statement, 13, project.isWorktree ? 1 : 0)
            sqlite3_bind_int64(statement, 14, project.isGitRepository ? 1 : 0)
            sqlite3_bind_int64(statement, 15, project.authorizedAt)
        }
    }

    public func updateProject(_ project: ProjectRecord) throws {
        try database.run("""
            UPDATE projects SET
                display_name = ?, canonical_path = ?, last_opened_at = ?,
                git_root = ?, branch = ?, preferred_agent = ?, preferred_model = ?,
                default_permission_profile = ?, last_session_id = ?,
                is_favorite = ?, is_worktree = ?, is_git_repository = ?, authorized_at = ?
            WHERE id = ?
            """) { statement in
            bind(project.displayName, to: statement, at: 1)
            bind(project.canonicalPath, to: statement, at: 2)
            bind(project.lastOpenedAt, to: statement, at: 3)
            bind(project.gitRoot, to: statement, at: 4)
            bind(project.branch, to: statement, at: 5)
            bind(project.preferredAgent?.rawValue, to: statement, at: 6)
            bind(project.preferredModel, to: statement, at: 7)
            bind(project.defaultPermissionProfile, to: statement, at: 8)
            bind(project.lastSessionID?.wireString, to: statement, at: 9)
            sqlite3_bind_int64(statement, 10, project.isFavorite ? 1 : 0)
            sqlite3_bind_int64(statement, 11, project.isWorktree ? 1 : 0)
            sqlite3_bind_int64(statement, 12, project.isGitRepository ? 1 : 0)
            sqlite3_bind_int64(statement, 13, project.authorizedAt)
            bind(project.id.wireString, to: statement, at: 14)
        }
    }

    public func project(id: ProjectID) throws -> ProjectRecord? {
        try database.query("SELECT * FROM projects WHERE id = ?1") { statement in
            bind(id.wireString, to: statement, at: 1)
        } map: { statement in
            try projectRecord(from: statement)
        }.first
    }

    public func project(matchingCanonicalPath path: String) throws -> ProjectRecord? {
        try database.query("SELECT * FROM projects WHERE canonical_path = ?1") { statement in
            bind(path, to: statement, at: 1)
        } map: { statement in
            try projectRecord(from: statement)
        }.first
    }

    public func listProjects() throws -> [ProjectRecord] {
        try database.query("SELECT * FROM projects ORDER BY display_name") { statement in
            try projectRecord(from: statement)
        }
    }

    public func deleteProject(id: ProjectID) throws {
        try database.run("DELETE FROM projects WHERE id = ?") { statement in
            bind(id.wireString, to: statement, at: 1)
        }
    }

    private nonisolated func projectRecord(from statement: OpaquePointer) throws -> ProjectRecord {
        guard
            let idText = textColumn(statement, 0),
            let id = ProjectID(idText),
            let name = textColumn(statement, 1),
            let path = textColumn(statement, 2)
        else {
            throw RepositoryError.statementFailed("malformed projects row")
        }
        let preferredAgent = textColumn(statement, 7).flatMap { AgentIdentifier($0) }
        let lastSession = textColumn(statement, 10).flatMap { SessionID($0) }
        return ProjectRecord(
            id: id,
            displayName: name,
            canonicalPath: path,
            createdAt: sqlite3_column_int64(statement, 3),
            lastOpenedAt: optionalInt64Column(statement, 4),
            gitRoot: textColumn(statement, 5),
            branch: textColumn(statement, 6),
            preferredAgent: preferredAgent,
            preferredModel: textColumn(statement, 8),
            defaultPermissionProfile: textColumn(statement, 9),
            lastSessionID: lastSession,
            isFavorite: sqlite3_column_int64(statement, 11) != 0,
            isWorktree: sqlite3_column_int64(statement, 12) != 0,
            isGitRepository: sqlite3_column_int64(statement, 13) != 0,
            authorizedAt: sqlite3_column_int64(statement, 14)
        )
    }

    // MARK: - Devices

    public func insertDevice(_ device: DeviceRecord) throws {
        try database.run("""
            INSERT INTO devices (id, display_name, paired_at, last_seen_at, revoked,
                public_key, tls_public_key_hash, capabilities, push_destination_token,
                last_known_endpoint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(device.id.wireString, to: statement, at: 1)
            bind(device.displayName, to: statement, at: 2)
            bind(device.pairedAt, to: statement, at: 3)
            bind(device.lastSeenAt, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, device.revoked ? 1 : 0)
            bind(device.publicKey, to: statement, at: 6)
            bind(device.tlsPublicKeyHash, to: statement, at: 7)
            bind(device.capabilities.map(\.rawValue).joined(separator: ","), to: statement, at: 8)
            bind(device.pushDestinationToken?.rawValue, to: statement, at: 9)
            bind(device.lastKnownEndpoint, to: statement, at: 10)
        }
    }

    public func device(id: DeviceID) throws -> DeviceRecord? {
        try database.query("SELECT * FROM devices WHERE id = ?1") { statement in
            bind(id.wireString, to: statement, at: 1)
        } map: { statement in
            try deviceRecord(from: statement)
        }.first
    }

    public func listDevices() throws -> [DeviceRecord] {
        try database.query("SELECT * FROM devices ORDER BY display_name") { statement in
            try deviceRecord(from: statement)
        }
    }

    public func setDeviceRevoked(_ id: DeviceID, revoked: Bool) throws {
        try database.run("UPDATE devices SET revoked = ? WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, revoked ? 1 : 0)
            bind(id.wireString, to: statement, at: 2)
        }
    }

    public func updateDeviceLastSeen(_ id: DeviceID, at: Int64) throws {
        try database.run("UPDATE devices SET last_seen_at = ? WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, at)
            bind(id.wireString, to: statement, at: 2)
        }
    }

    public func updateDevicePushToken(_ id: DeviceID, token: PushDestinationToken?) throws {
        try database.run("UPDATE devices SET push_destination_token = ? WHERE id = ?") { statement in
            bind(token?.rawValue, to: statement, at: 1)
            bind(id.wireString, to: statement, at: 2)
        }
    }

    public func updateDeviceEndpoint(_ id: DeviceID, endpoint: String?) throws {
        try database.run("UPDATE devices SET last_known_endpoint = ? WHERE id = ?") { statement in
            bind(endpoint, to: statement, at: 1)
            bind(id.wireString, to: statement, at: 2)
        }
    }

    public func deleteDevice(id: DeviceID) throws {
        try database.run("DELETE FROM devices WHERE id = ?") { statement in
            bind(id.wireString, to: statement, at: 1)
        }
    }

    private nonisolated func deviceRecord(from statement: OpaquePointer) throws -> DeviceRecord {
        guard
            let idText = textColumn(statement, 0),
            let id = DeviceID(idText),
            let name = textColumn(statement, 1)
        else {
            throw RepositoryError.statementFailed("malformed devices row")
        }
        let capabilitiesText = textColumn(statement, 7) ?? ""
        let capabilities = capabilitiesText.isEmpty
            ? []
            : capabilitiesText.split(separator: ",").compactMap { PeerCapability(rawValue: String($0)) }
        let pushToken = textColumn(statement, 8).flatMap(PushDestinationToken.init)
        let endpoint = textColumn(statement, 9)
        return DeviceRecord(
            id: id,
            displayName: name,
            publicKey: blobColumn(statement, 5),
            tlsPublicKeyHash: textColumn(statement, 6),
            capabilities: capabilities,
            pairedAt: optionalInt64Column(statement, 2),
            lastSeenAt: optionalInt64Column(statement, 3),
            revoked: sqlite3_column_int64(statement, 4) != 0,
            pushDestinationToken: pushToken,
            lastKnownEndpoint: endpoint
        )
    }

    // MARK: - Attachments

    public func insertAttachment(_ attachment: AttachmentRecord) throws {
        try database.run("""
            INSERT INTO attachments (id, session_id, file_name, byte_count, mime_type, created_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(attachment.id.uuidString.lowercased(), to: statement, at: 1)
            bind(attachment.sessionID?.wireString, to: statement, at: 2)
            bind(attachment.fileName, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, attachment.byteCount)
            bind(attachment.mimeType, to: statement, at: 5)
            sqlite3_bind_int64(statement, 6, attachment.createdAt)
            bind(attachment.deletedAt, to: statement, at: 7)
        }
    }

    public func markAttachmentDeleted(id: UUID, deletedAt: Int64) throws {
        try database.run("UPDATE attachments SET deleted_at = ? WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, deletedAt)
            bind(id.uuidString.lowercased(), to: statement, at: 2)
        }
    }

    public func attachments(sessionID: SessionID) throws -> [AttachmentRecord] {
        try database.query("SELECT * FROM attachments WHERE session_id = ?1 ORDER BY created_at") { statement in
            bind(sessionID.wireString, to: statement, at: 1)
        } map: { statement in
            try attachmentRecord(from: statement)
        }
    }

    public func listAttachments() throws -> [AttachmentRecord] {
        try database.query("SELECT * FROM attachments ORDER BY created_at") { statement in
            try attachmentRecord(from: statement)
        }
    }

    private nonisolated func attachmentRecord(from statement: OpaquePointer) throws -> AttachmentRecord {
        guard
            let idText = textColumn(statement, 0),
            let id = UUID(uuidString: idText),
            let fileName = textColumn(statement, 2)
        else {
            throw RepositoryError.statementFailed("malformed attachments row")
        }
        return AttachmentRecord(
            id: id,
            sessionID: textColumn(statement, 1).flatMap { SessionID($0) },
            fileName: fileName,
            byteCount: sqlite3_column_int64(statement, 3),
            mimeType: textColumn(statement, 4),
            createdAt: sqlite3_column_int64(statement, 5),
            deletedAt: optionalInt64Column(statement, 6)
        )
    }

    // MARK: - Maintenance

    public func vacuum() throws {
        try database.execute("VACUUM")
    }

    /// Forces a WAL checkpoint and truncates the journal. Maintenance hook
    /// for retention flows and tests (the store uses WAL mode).
    public func checkpoint() throws {
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Column/binding helpers

    private nonisolated func checkedInt64(_ value: UInt64, field: String) throws -> Int64 {
        guard let int = Int64(exactly: value) else {
            throw RepositoryError.integerOverflow(field)
        }
        return int
    }

    private nonisolated func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLiteDatabase.transient)
    }

    private nonisolated func bind(_ value: Data?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            _ = value.withUnsafeBytes { buffer -> Int32 in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLiteDatabase.transient)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private nonisolated func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            bind(value, to: statement, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private nonisolated func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private nonisolated func blobColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private nonisolated func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private nonisolated func optionalInt64Column(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }
}

// MARK: - Low-level database wrapper

/// Minimal SQLite3 handle wrapper: exec, transaction, prepared statements.
/// File-private to the store; all calls are actor-confined through it.
private final class SQLiteDatabase {
    /// SQLITE_TRANSIENT: SQLite copies bound strings.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let handle: OpaquePointer

    deinit {
        sqlite3_close(handle)
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw RepositoryError.openFailed(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    /// Executes a statement returning no rows.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw RepositoryError.statementFailed("\(message) — in: \(sql.prefix(120))")
        }
    }

    /// Runs a prepared mutation; returns the number of changed rows.
    @discardableResult
    func run(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("step failed")
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a prepared query, mapping each row.
    func query<T>(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void = { _ in },
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try map(statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw lastError("step failed")
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try execute("COMMIT")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError("prepare failed")
        }
        return statement
    }

    private func lastError(_ prefix: String) -> RepositoryError {
        let message = String(cString: sqlite3_errmsg(handle))
        if message.contains("UNIQUE constraint") || message.contains("FOREIGN KEY constraint") {
            return .constraintViolation(message)
        }
        return .statementFailed("\(prefix): \(message)")
    }
}
