//
//  StateSyncMirror.swift
//  App — AgentDeck
//
//  Mirrors Mac-originated state-sync frames (project.list.response,
//  agent.list.response, agent.snapshot) into local state, following the
//  SessionEventMirror pattern. Projects persist into the SessionRepository;
//  agents have no repository table, so they persist into a small
//  UserDefaults-backed store (see note on SyncedAgentStore).
//
//  Wire payloads are decoded leniently: `payloadV` is tolerated but not
//  required, and unknown fields are ignored, so the client keeps working
//  while the companion contract lands.
//

import Foundation
import Shared

// MARK: - Wire models

/// One project entry from `project.list.response`
/// (`{id, displayName, pathHint, gitBranch?, gitState?}`).
struct SyncedProject: Sendable, Equatable {
    let id: ProjectID
    let displayName: String
    let pathHint: String
    let gitBranch: String?
    /// Opaque companion-provided git state string (e.g. "clean"/"dirty").
    /// ProjectRecord has no column for it; the app keeps it in memory only.
    let gitState: String?
}

/// One agent entry from `agent.list.response` / `agent.snapshot`
/// (`{id, displayName, installed, version?, activeSessions, totalSessions,
/// reliabilityClass}`). `reliabilityClass` is opaque and rendered as-is.
struct SyncedAgent: Sendable, Equatable, Codable, Identifiable {
    let id: AgentIdentifier
    var displayName: String
    var installed: Bool
    var version: String?
    var activeSessions: Int
    var totalSessions: Int
    var reliabilityClass: String
}

/// The `diff.content` response for one session
/// (`{sessionID, unifiedDiff, files:[{path, additions, deletions}], truncated}`).
struct SessionDiffContent: Sendable, Equatable {
    struct FileStat: Sendable, Equatable, Identifiable {
        let path: String
        let additions: Int64
        let deletions: Int64

        var id: String { path }
    }

    let sessionID: SessionID
    let unifiedDiff: String
    let files: [FileStat]
    let truncated: Bool
    let receivedAt: Int64

    var totalAdditions: Int64 { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int64 { files.reduce(0) { $0 + $1.deletions } }
}

/// The `attachment.init.response` (`{transferID, chunkSize}`).
struct AttachmentInitResponse: Sendable, Equatable {
    let transferID: String
    let chunkSize: Int
}

/// The `attachment.ack` (`{transferID, status, reason?}`). Status values are
/// companion-defined; the client accepts "accepted"/"ok" and treats anything
/// else as a rejection, surfacing `reason` when present.
struct AttachmentAck: Sendable, Equatable {
    let transferID: String
    let status: String
    let reason: String?

    var isAccepted: Bool {
        status == "accepted" || status == "ok"
    }
}

/// State-sync messages dispatched from the connection serve loop.
enum StateSyncMessage: Sendable {
    case projectList(JSONValue)
    case agentList(JSONValue)
    case agentSnapshot(JSONValue)
}

enum StateSyncWireError: Error, Equatable {
    case invalidIdentifier(field: String, value: String)
}

// MARK: - Wire decoding (lenient; see file header)

enum StateSyncWire {
    static func decodeProjects(_ payload: JSONValue) throws -> [SyncedProject] {
        try payload.arrayField("projects").map { value in
            let idText = try value.stringField("id")
            guard let id = ProjectID(idText) else {
                throw StateSyncWireError.invalidIdentifier(field: "id", value: idText)
            }
            return SyncedProject(
                id: id,
                displayName: try value.stringField("displayName"),
                pathHint: try value.stringField("pathHint"),
                gitBranch: try value.optionalStringField("gitBranch"),
                gitState: try value.optionalStringField("gitState")
            )
        }
    }

    static func decodeAgents(_ payload: JSONValue) throws -> [SyncedAgent] {
        try payload.arrayField("agents").map { value in
            let idText = try value.stringField("id")
            guard let id = AgentIdentifier(idText) else {
                throw StateSyncWireError.invalidIdentifier(field: "id", value: idText)
            }
            return SyncedAgent(
                id: id,
                displayName: try value.stringField("displayName"),
                installed: try value.boolField("installed"),
                version: try value.optionalStringField("version"),
                activeSessions: Int(try value.intField("activeSessions")),
                totalSessions: Int(try value.intField("totalSessions")),
                reliabilityClass: try value.stringField("reliabilityClass")
            )
        }
    }

    static func decodeDiffContent(_ payload: JSONValue) throws -> SessionDiffContent {
        let sessionText = try payload.stringField("sessionID")
        guard let sessionID = SessionID(sessionText) else {
            throw StateSyncWireError.invalidIdentifier(field: "sessionID", value: sessionText)
        }
        let files = try payload.arrayField("files").map { value in
            SessionDiffContent.FileStat(
                path: try value.stringField("path"),
                additions: try value.intField("additions"),
                deletions: try value.intField("deletions")
            )
        }
        return SessionDiffContent(
            sessionID: sessionID,
            unifiedDiff: try payload.stringField("unifiedDiff"),
            files: files,
            truncated: try payload.boolField("truncated"),
            receivedAt: Date.unixMillisecondsNow
        )
    }

    static func decodeAttachmentInitResponse(_ payload: JSONValue) throws -> AttachmentInitResponse {
        AttachmentInitResponse(
            transferID: try payload.stringField("transferID"),
            chunkSize: Int(try payload.intField("chunkSize"))
        )
    }

    static func decodeAttachmentAck(_ payload: JSONValue) throws -> AttachmentAck {
        AttachmentAck(
            transferID: try payload.stringField("transferID"),
            status: try payload.stringField("status"),
            reason: try payload.optionalStringField("reason")
        )
    }
}

// MARK: - Mirror

/// Persists synced projects into the local repository (mirror pattern, no
/// rebroadcast). Agent snapshots have no repository table and stay with the
/// caller's `SyncedAgentStore`.
struct StateSyncMirror: Sendable {
    private let repository: any SessionRepository

    init(repository: any SessionRepository) {
        self.repository = repository
    }

    /// Upserts synced projects. `pathHint` is the only path the wire
    /// provides, so it fills ProjectRecord.canonicalPath (informational only
    /// on iOS — the Mac remains the path authority).
    func mirrorProjects(_ projects: [SyncedProject], at now: Int64 = Date.unixMillisecondsNow) async throws {
        for project in projects {
            let isGit = project.gitBranch != nil || project.gitState != nil
            if var existing = try await repository.project(id: project.id) {
                existing.displayName = project.displayName
                existing.canonicalPath = project.pathHint
                existing.branch = project.gitBranch
                existing.isGitRepository = isGit
                try await repository.updateProject(existing)
            } else {
                try await repository.insertProject(
                    ProjectRecord(
                        id: project.id,
                        displayName: project.displayName,
                        canonicalPath: project.pathHint,
                        createdAt: now,
                        branch: project.gitBranch,
                        isGitRepository: isGit,
                        authorizedAt: now
                    )
                )
            }
        }
    }
}

// MARK: - Agent snapshot persistence

/// Durable store for the latest synced agent snapshot. The SessionRepository
/// has no agent table, so snapshots persist as JSON in UserDefaults — the
/// state is small, non-secret companion metadata.
struct SyncedAgentStore: Sendable {
    private static let key = "agentdeck.syncedAgents.v1"

    func load() -> [SyncedAgent] {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([SyncedAgent].self, from: data)) ?? []
    }

    func save(_ agents: [SyncedAgent]) {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
