//
//  SessionRepository.swift
//  Shared — AgentDeck
//
//  §12.5 session database: repository abstraction (ADR-0002 — SQLite via
//  the system SQLite3 C API lives behind this protocol; the companion owns
//  the single writer actor). The schema is versioned with explicit
//  migrations; app upgrades must never lose session history. No raw
//  secrets are ever persisted (Constitution #8) — JSON payloads are
//  redacted with `Redactor` on write.
//

import Foundation

// MARK: - Records (DTOs for the persisted schema)

public enum SessionOrigin: String, Codable, Sendable, CaseIterable {
    case iosLaunch
    case companionLaunch
    case cliWrapper
    case externalImport
}

/// Opaque provider-owned resume identity. The identifier is never interpreted
/// by AgentDeck and is only returned to the matching adapter.
public struct ProviderSessionReference: Codable, Sendable, Equatable {
    public var providerID: AgentIdentifier
    public var externalSessionID: String
    public var compatibilityVersion: String?
    public var importedAt: Int64

    public init(
        providerID: AgentIdentifier,
        externalSessionID: String,
        compatibilityVersion: String? = nil,
        importedAt: Int64
    ) {
        self.providerID = providerID
        self.externalSessionID = externalSessionID
        self.compatibilityVersion = compatibilityVersion
        self.importedAt = importedAt
    }
}

/// Persisted session metadata (§12.5).
public struct SessionRecord: Sendable, Equatable {
    public var id: SessionID
    public var agent: AgentIdentifier
    public var projectID: ProjectID?
    public var state: SessionActivityState
    /// Provider-side resume identifier, when the agent supports resume (§12.5).
    public var agentResumeIdentifier: String?
    public var origin: SessionOrigin
    public var providerSessionReference: ProviderSessionReference?
    /// Unix ms.
    public var createdAt: Int64
    public var updatedAt: Int64
    public var endedAt: Int64?
    public var completionSummary: String?

    public init(
        id: SessionID,
        agent: AgentIdentifier,
        projectID: ProjectID? = nil,
        state: SessionActivityState = .starting,
        agentResumeIdentifier: String? = nil,
        origin: SessionOrigin = .iosLaunch,
        providerSessionReference: ProviderSessionReference? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        endedAt: Int64? = nil,
        completionSummary: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.projectID = projectID
        self.state = state
        self.agentResumeIdentifier = agentResumeIdentifier
        self.origin = origin
        self.providerSessionReference = providerSessionReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.completionSummary = completionSummary
    }

    /// Non-terminal per §10.3 — drives the menu's active-session count (§12.6).
    public var isActive: Bool { !state.isTerminal }
}

/// A persisted timeline event (payload stored redacted, §12.5).
public struct EventRecord: Sendable, Equatable {
    public var id: EventID
    public var sessionID: SessionID
    /// Per-session sequence — matches the §9 EventCursor ordering.
    public var sequence: UInt64
    public var timestamp: Int64
    public var confidence: EventConfidence
    /// Wire discriminator (AgentEventPayload.kind) — stable strings.
    public var kind: String
    public var payload: JSONValue

    public init(
        id: EventID,
        sessionID: SessionID,
        sequence: UInt64,
        timestamp: Int64,
        confidence: EventConfidence,
        kind: String,
        payload: JSONValue
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.confidence = confidence
        self.kind = kind
        self.payload = payload
    }
}

/// A persisted approval request plus its decision, when resolved (§12.5).
public struct ApprovalRecord: Sendable, Equatable {
    public var request: ApprovalRequest
    public var decision: ApprovalDecision?
    public var resolvedAt: Int64?

    public init(request: ApprovalRequest, decision: ApprovalDecision? = nil, resolvedAt: Int64? = nil) {
        self.request = request
        self.decision = decision
        self.resolvedAt = resolvedAt
    }

    public var isPending: Bool { decision == nil }
}

/// Persisted approval rule state (§15.5).
public struct ApprovalRuleRecord: Sendable, Equatable {
    public var rule: ApprovalRule

    public init(rule: ApprovalRule) {
        self.rule = rule
    }
}

/// Persisted audit trail entries for approval decisions (§15.4 audit history).
public struct ApprovalAuditRecord: Sendable, Equatable {
    public var entry: ApprovalAuditEntry

    public init(entry: ApprovalAuditEntry) {
        self.entry = entry
    }
}

/// A user-authorized project (§12.4; enriched in Phase 4).
public struct ProjectRecord: Sendable, Equatable {
    public var id: ProjectID
    public var displayName: String
    /// Canonical path — symlink-resolved before storage (§12.3, §16).
    public var canonicalPath: String
    public var createdAt: Int64
    public var lastOpenedAt: Int64?
    /// Git root when the project is inside a repository (Phase 4).
    public var gitRoot: String?
    public var branch: String?
    public var preferredAgent: AgentIdentifier?
    public var preferredModel: String?
    public var defaultPermissionProfile: String?
    public var lastSessionID: SessionID?
    public var isFavorite: Bool
    public var isWorktree: Bool
    public var isGitRepository: Bool
    /// When the user last explicitly authorized/reauthorized this path.
    public var authorizedAt: Int64

    public init(
        id: ProjectID,
        displayName: String,
        canonicalPath: String,
        createdAt: Int64,
        lastOpenedAt: Int64? = nil,
        gitRoot: String? = nil,
        branch: String? = nil,
        preferredAgent: AgentIdentifier? = nil,
        preferredModel: String? = nil,
        defaultPermissionProfile: String? = nil,
        lastSessionID: SessionID? = nil,
        isFavorite: Bool = false,
        isWorktree: Bool = false,
        isGitRepository: Bool = false,
        authorizedAt: Int64? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.gitRoot = gitRoot
        self.branch = branch
        self.preferredAgent = preferredAgent
        self.preferredModel = preferredModel
        self.defaultPermissionProfile = defaultPermissionProfile
        self.lastSessionID = lastSessionID
        self.isFavorite = isFavorite
        self.isWorktree = isWorktree
        self.isGitRepository = isGitRepository
        self.authorizedAt = authorizedAt ?? createdAt
    }
}

/// A paired device (§13.2 persistence: peer public key, display name,
/// pairing date, last-seen, granted capabilities, revocation state).
public struct DeviceRecord: Sendable, Equatable {
    public var id: DeviceID
    public var displayName: String
    /// The peer's Ed25519 identity public key (32 bytes), pinned at pairing.
    public var publicKey: Data?
    /// The peer's TLS public-key hash pinned at pairing (§13.4, ADR-0008).
    public var tlsPublicKeyHash: String?
    /// §13.2 granted capabilities.
    public var capabilities: [PeerCapability]
    public var pairedAt: Int64?
    public var lastSeenAt: Int64?
    public var revoked: Bool
    /// §14.3 opaque APNs destination token for background alerts.
    public var pushDestinationToken: PushDestinationToken?
    /// Last known "host:port" for reconnect (from QR payload or successful connect).
    public var lastKnownEndpoint: String?

    public init(
        id: DeviceID,
        displayName: String,
        publicKey: Data? = nil,
        tlsPublicKeyHash: String? = nil,
        capabilities: [PeerCapability] = [],
        pairedAt: Int64? = nil,
        lastSeenAt: Int64? = nil,
        revoked: Bool = false,
        pushDestinationToken: PushDestinationToken? = nil,
        lastKnownEndpoint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.publicKey = publicKey
        self.tlsPublicKeyHash = tlsPublicKeyHash
        self.capabilities = capabilities
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.revoked = revoked
        self.pushDestinationToken = pushDestinationToken
        self.lastKnownEndpoint = lastKnownEndpoint
    }

    public var peerEndpoint: PeerEndpoint? {
        guard let lastKnownEndpoint else { return nil }
        return PeerEndpoint(lastKnownEndpoint)
    }
}

/// Attachment metadata (§12.5); file contents live in the companion-managed
/// temp directory (§16.2), never in the database.
public struct AttachmentRecord: Sendable, Equatable {
    public var id: UUID
    public var sessionID: SessionID?
    public var fileName: String
    public var byteCount: Int64
    public var mimeType: String?
    public var createdAt: Int64
    public var deletedAt: Int64?

    public init(
        id: UUID,
        sessionID: SessionID? = nil,
        fileName: String,
        byteCount: Int64,
        mimeType: String? = nil,
        createdAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.fileName = fileName
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Errors

public enum RepositoryError: Error, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case constraintViolation(String)
    case conflict(String)
    case notFound
    /// A counter exceeded the Int64 storage range.
    case integerOverflow(String)
}

// MARK: - Repository protocol

/// The §12.5 session database, behind a protocol (ADR-0002). The companion
/// owns the single writer actor; reads and writes both go through these
/// methods so a future store (e.g. SwiftData) could replace SQLite without
/// touching call sites.
public protocol SessionRepository: Sendable {
    /// Highest applied schema version (0 = empty database).
    func schemaVersion() async throws -> Int

    // Sessions
    func insertSession(_ session: SessionRecord) async throws
    func session(id: SessionID) async throws -> SessionRecord?
    func updateSessionState(
        id: SessionID,
        state: SessionActivityState,
        updatedAt: Int64,
        endedAt: Int64?,
        completionSummary: String?
    ) async throws
    func listSessions() async throws -> [SessionRecord]
    /// §12.6 menu count: sessions not in a terminal state.
    func countActiveSessions() async throws -> Int
    /// Deletes a session; its events and approvals cascade (§21 delete session).
    func deleteSession(id: SessionID) async throws -> Int

    // Events (timeline)
    func insertEvent(_ event: EventRecord) async throws
    /// Ordered by sequence; `afterSequence` is exclusive (cursor resume, §14.1).
    func events(sessionID: SessionID, afterSequence: UInt64?, limit: Int) async throws -> [EventRecord]

    // Approvals
    func insertApproval(_ record: ApprovalRecord) async throws
    /// Persists the decision. `RepositoryError.conflict` when a decision
    /// already exists — the §9 idempotency policy lives in ApprovalResolver;
    /// the store refuses silent overwrites (data integrity, §5.4).
    func recordApprovalDecision(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        resolvedAt: Int64
    ) async throws
    func approvals(sessionID: SessionID) async throws -> [ApprovalRecord]
    func pendingApprovals(limit: Int) async throws -> [ApprovalRecord]
    /// §12.6 menu count.
    func countPendingApprovals() async throws -> Int
    func insertApprovalRule(_ rule: ApprovalRule) async throws
    func listApprovalRules(projectID: ProjectID?, sessionID: SessionID?) async throws -> [ApprovalRule]
    func revokeApprovalRule(id: ApprovalRuleID, revokedAt: Int64) async throws
    func insertApprovalAuditEntry(_ entry: ApprovalAuditEntry) async throws
    func approvalAuditEntries(sessionID: SessionID?, limit: Int) async throws -> [ApprovalAuditEntry]

    // Projects
    func insertProject(_ project: ProjectRecord) async throws
    func updateProject(_ project: ProjectRecord) async throws
    func project(id: ProjectID) async throws -> ProjectRecord?
    func project(matchingCanonicalPath path: String) async throws -> ProjectRecord?
    func listProjects() async throws -> [ProjectRecord]
    func deleteProject(id: ProjectID) async throws

    // Devices
    func insertDevice(_ device: DeviceRecord) async throws
    func device(id: DeviceID) async throws -> DeviceRecord?
    func listDevices() async throws -> [DeviceRecord]
    /// §13.3: revocation terminates the connection immediately and
    /// invalidates credentials (transport enforces at connect time).
    func setDeviceRevoked(_ id: DeviceID, revoked: Bool) async throws
    func updateDeviceLastSeen(_ id: DeviceID, at: Int64) async throws
    func updateDevicePushToken(_ id: DeviceID, token: PushDestinationToken?) async throws
    func updateDeviceEndpoint(_ id: DeviceID, endpoint: String?) async throws
    func deleteDevice(id: DeviceID) async throws

    // Attachments (metadata)
    func insertAttachment(_ attachment: AttachmentRecord) async throws
    func markAttachmentDeleted(id: UUID, deletedAt: Int64) async throws
    func attachments(sessionID: SessionID) async throws -> [AttachmentRecord]
    func listAttachments() async throws -> [AttachmentRecord]

    /// Reclaims space after retention deletions (§23 budget).
    func vacuum() async throws
}
