//
//  StateSyncFrames.swift
//  Shared — AgentDeck
//
//  §9/§29 state-sync payloads: project + agent inventory, terminal session
//  lifecycle, and diff content mirroring. All additive to the v1 envelope
//  (ADR-0012/ADR-0013 family); each payload is versioned with payloadV.
//

import Foundation

public enum StateSyncPayloadVersion: Int64, Sendable {
    case v1 = 1
}

// MARK: - Terminal session lifecycle

/// Device → companion: launch a login-shell PTY inside an authorized
/// project. The companion derives the working directory from the project
/// record; clients never supply paths (§16 containment).
public struct TerminalStartRequest: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var projectID: ProjectID
    public var cols: Int
    public var rows: Int

    public init(projectID: ProjectID, cols: Int = 80, rows: Int = 24) {
        self.projectID = projectID
        self.cols = cols
        self.rows = rows
    }
}

extension TerminalStartRequest: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.projectID = try jsonValue.nestedField("projectID", as: ProjectID.self)
        self.cols = Int(try jsonValue.optionalIntField("cols") ?? 80)
        self.rows = Int(try jsonValue.optionalIntField("rows") ?? 24)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("projectID", projectID.toJSONValue()),
            ("cols", .int(Int64(cols))),
            ("rows", .int(Int64(rows)))
        ])
    }
}

/// Companion → device: answer to terminal.start with the new PTY session id.
public struct TerminalStartedResponse: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var projectID: ProjectID

    public init(sessionID: SessionID, projectID: ProjectID) {
        self.sessionID = sessionID
        self.projectID = projectID
    }
}

extension TerminalStartedResponse: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        self.sessionID = sessionID
        self.projectID = try jsonValue.nestedField("projectID", as: ProjectID.self)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString)),
            ("projectID", projectID.toJSONValue())
        ])
    }
}

/// Device → companion: attach to a live PTY session and replay its
/// scrollback (isReplay terminal.output chunks follow on this connection).
public struct TerminalAttachRequest: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

extension TerminalAttachRequest: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        self.sessionID = sessionID
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString))
        ])
    }
}

/// Device → companion: PTY window resize (TIOCSWINSZ).
public struct TerminalResizeRequest: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var cols: Int
    public var rows: Int

    public init(sessionID: SessionID, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

extension TerminalResizeRequest: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        self.sessionID = sessionID
        self.cols = Int(try jsonValue.intField("cols"))
        self.rows = Int(try jsonValue.intField("rows"))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString)),
            ("cols", .int(Int64(cols))),
            ("rows", .int(Int64(rows)))
        ])
    }
}

// MARK: - Project inventory

/// A synced project entry. `pathHint` is the trailing path component only —
/// full canonical paths stay on the Mac (§18 data minimization on caches).
public struct ProjectSummary: Sendable, Equatable {
    public var id: ProjectID
    public var displayName: String
    public var pathHint: String
    public var gitBranch: String?
    public var isGitRepository: Bool
    public var isWorktree: Bool

    public init(
        id: ProjectID,
        displayName: String,
        pathHint: String,
        gitBranch: String? = nil,
        isGitRepository: Bool = false,
        isWorktree: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.gitBranch = gitBranch
        self.isGitRepository = isGitRepository
        self.isWorktree = isWorktree
    }

    public init(record: ProjectRecord) {
        self.init(
            id: record.id,
            displayName: record.displayName,
            pathHint: URL(fileURLWithPath: record.canonicalPath).lastPathComponent,
            gitBranch: record.branch,
            isGitRepository: record.isGitRepository,
            isWorktree: record.isWorktree
        )
    }
}

extension ProjectSummary: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        self.id = try jsonValue.nestedField("id", as: ProjectID.self)
        self.displayName = try jsonValue.stringField("displayName")
        self.pathHint = try jsonValue.stringField("pathHint")
        self.gitBranch = try jsonValue.optionalStringField("gitBranch")
        self.isGitRepository = (try? jsonValue.boolField("isGitRepository")) ?? false
        self.isWorktree = (try? jsonValue.boolField("isWorktree")) ?? false
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("id", id.toJSONValue()),
            ("displayName", .string(displayName)),
            ("pathHint", .string(pathHint)),
            ("isGitRepository", .bool(isGitRepository)),
            ("isWorktree", .bool(isWorktree))
        ]
        if let gitBranch {
            pairs.append(("gitBranch", .string(gitBranch)))
        }
        return .object(pairs)
    }
}

/// Companion → device: answer to project.list.
public struct ProjectListResponse: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var projects: [ProjectSummary]

    public init(projects: [ProjectSummary]) {
        self.projects = projects
    }
}

extension ProjectListResponse: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.projects = try jsonValue.arrayField("projects").map(ProjectSummary.init(jsonValue:))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("projects", .array(projects.map { $0.toJSONValue() }))
        ])
    }
}

// MARK: - Agent inventory

/// One synced agent card (§6 Home): installed runtime state plus live
/// session counts and the §9 integration reliability class.
public struct AgentCardState: Sendable, Equatable {
    public var id: AgentIdentifier
    public var displayName: String
    public var installed: Bool
    public var version: String?
    public var activeSessions: Int
    public var totalSessions: Int
    public var reliabilityClass: String

    public init(
        id: AgentIdentifier,
        displayName: String,
        installed: Bool,
        version: String? = nil,
        activeSessions: Int = 0,
        totalSessions: Int = 0,
        reliabilityClass: String = "rawOnly"
    ) {
        self.id = id
        self.displayName = displayName
        self.installed = installed
        self.version = version
        self.activeSessions = activeSessions
        self.totalSessions = totalSessions
        self.reliabilityClass = reliabilityClass
    }
}

extension AgentCardState: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let id = AgentIdentifier(try jsonValue.stringField("id")) else {
            throw JSONValueDecodingError.invalidValue(field: "id", reason: "invalid agent identifier")
        }
        self.id = id
        self.displayName = try jsonValue.stringField("displayName")
        self.installed = (try? jsonValue.boolField("installed")) ?? false
        self.version = try jsonValue.optionalStringField("version")
        self.activeSessions = Int((try? jsonValue.intField("activeSessions")) ?? 0)
        self.totalSessions = Int((try? jsonValue.intField("totalSessions")) ?? 0)
        self.reliabilityClass = (try? jsonValue.stringField("reliabilityClass")) ?? "rawOnly"
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("id", .string(id.rawValue)),
            ("displayName", .string(displayName)),
            ("installed", .bool(installed)),
            ("activeSessions", .int(Int64(activeSessions))),
            ("totalSessions", .int(Int64(totalSessions))),
            ("reliabilityClass", .string(reliabilityClass))
        ]
        if let version {
            pairs.append(("version", .string(version)))
        }
        return .object(pairs)
    }
}

/// Companion → device: answer to agent.list, and the pushed `agent.snapshot`
/// broadcast (on connect and whenever session counts change).
public struct AgentSnapshot: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var agents: [AgentCardState]

    public init(agents: [AgentCardState]) {
        self.agents = agents
    }
}

extension AgentSnapshot: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.agents = try jsonValue.arrayField("agents").map(AgentCardState.init(jsonValue:))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("agents", .array(agents.map { $0.toJSONValue() }))
        ])
    }
}

// MARK: - Diff content mirroring

/// Device → companion: request the unified diff for a session's project.
public struct DiffRequest: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var maxBytes: Int?

    public init(sessionID: SessionID, maxBytes: Int? = nil) {
        self.sessionID = sessionID
        self.maxBytes = maxBytes
    }
}

extension DiffRequest: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        self.sessionID = sessionID
        self.maxBytes = try jsonValue.optionalIntField("maxBytes").map(Int.init)
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString))
        ]
        if let maxBytes {
            pairs.append(("maxBytes", .int(Int64(maxBytes))))
        }
        return .object(pairs)
    }
}

public struct DiffFileSummary: Sendable, Equatable {
    public var path: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

extension DiffFileSummary: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        self.path = try jsonValue.stringField("path")
        self.additions = Int((try? jsonValue.intField("additions")) ?? 0)
        self.deletions = Int((try? jsonValue.intField("deletions")) ?? 0)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("path", .string(path)),
            ("additions", .int(Int64(additions))),
            ("deletions", .int(Int64(deletions)))
        ])
    }
}

/// Companion → device: the mirrored diff content, honestly marked when the
/// byte cap truncated the result.
public struct DiffContent: Sendable, Equatable {
    public static let payloadV: Int64 = StateSyncPayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var unifiedDiff: String
    public var files: [DiffFileSummary]
    public var truncated: Bool

    public init(sessionID: SessionID, unifiedDiff: String, files: [DiffFileSummary], truncated: Bool) {
        self.sessionID = sessionID
        self.unifiedDiff = unifiedDiff
        self.files = files
        self.truncated = truncated
    }
}

extension DiffContent: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField("payloadV")
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        self.sessionID = sessionID
        self.unifiedDiff = try jsonValue.stringField("unifiedDiff")
        self.files = try jsonValue.arrayField("files").map(DiffFileSummary.init(jsonValue:))
        self.truncated = (try? jsonValue.boolField("truncated")) ?? false
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString)),
            ("unifiedDiff", .string(unifiedDiff)),
            ("files", .array(files.map { $0.toJSONValue() })),
            ("truncated", .bool(truncated))
        ])
    }
}
