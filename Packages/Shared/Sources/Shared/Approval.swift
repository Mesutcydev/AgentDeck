//
//  Approval.swift
//  Shared — AgentDeck
//
//  Approval model: §15.1 v1 choices, §15.4 risk classifications, §15.3
//  request contents, §9 idempotent resolve semantics.
//  No case for unrestricted global auto-approval exists anywhere in this
//  model — that absence is deliberate and normative (Constitution #6).
//

import Foundation

/// Default JSONValueConvertible conformance for string-raw-value enums.
extension JSONValueConvertible where Self: RawRepresentable, Self.RawValue == String {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = Self(rawValue: raw) else {
            throw JSONValueDecodingError.invalidValue(
                field: String(describing: Self.self), reason: "unknown case"
            )
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(rawValue) }
}

/// §15.1 v1 approval choices. Scoped decisions only — there is NO
/// "always approve everything" case, and adding one would violate
/// Constitution #6.
public enum ApprovalChoice: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case deny
    case allowOnce
    case allowSession
    case allowCommandPatternInProject
    case allowReadOnlyActions

    /// Whether the choice authorizes the action at all (deny does not).
    public var authorizes: Bool { self != .deny }
}

/// §15.4 risk classifications.
public enum RiskClassification: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case informational
    case low
    case medium
    case high
    case critical
    case unknown

    /// §15.4: critical actions require expanded explanation, exact command
    /// display, hold-to-confirm, device authentication, no notification-only
    /// approval, and an audit-log entry (enforced by the Phase 8 engine and
    /// UI; flagged here so every consumer sees the same rule).
    public var requiresSecureConfirmation: Bool { self == .critical }

    /// §14.2: high-risk approvals always require opening the app.
    public var requiresOpeningApp: Bool {
        self == .high || self == .critical || self == .unknown
    }
}

/// §15.3 reversibility of the requested action.
public enum Reversibility: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case reversible
    case irreversible
    case unknown
}

/// §15.3 approval request contents. The `confidence` field is an
/// `ApprovalEligibleConfidence` — a request with confidence below 0.7
/// (§10.4) cannot be CONSTRUCTED; the approval-card path is closed at the
/// type level, not by convention.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public static let payloadV: Int64 = 1
    /// §15.3 default time-to-live when a request carries no explicit
    /// `expiresAt`: five minutes. A request past its expiry resolves to a
    /// terminal expired state and can no longer be decided.
    public static let defaultTTLMilliseconds: Int64 = 300_000

    public let id: ApprovalRequestID
    public let agent: AgentIdentifier
    public let projectID: ProjectID
    public let sessionID: SessionID
    /// Tool the agent wants to invoke (e.g. a shell or file tool name).
    public let tool: String
    /// The exact action (e.g. the exact command line) — §15.3.
    public let exactAction: String
    /// Human-readable explanation of what and why — §15.3, §15.5 style.
    public let explanation: String
    public let files: [String]
    public let domains: [String]
    public let workingDirectory: String
    public let risk: RiskClassification
    public let reversibility: Reversibility
    /// Requested duration in seconds; nil means a single action (§15.3).
    public let requestedDurationSeconds: Int64?
    /// Raw provider payload for transparency/debugging (§15.3). Stored as
    /// generic JSONValue — never decoded into provider-specific types here.
    public let originalProviderPayload: JSONValue
    /// §10.4 confidence, type-gated to ≥ 0.7.
    public let confidence: ApprovalEligibleConfidence
    /// Unix ms.
    public let createdAt: Int64
    /// Unix ms deadline for a decision; nil falls back to
    /// `createdAt + defaultTTLMilliseconds` (see `isExpired`).
    public let expiresAt: Int64?

    public init(
        id: ApprovalRequestID,
        agent: AgentIdentifier,
        projectID: ProjectID,
        sessionID: SessionID,
        tool: String,
        exactAction: String,
        explanation: String,
        files: [String] = [],
        domains: [String] = [],
        workingDirectory: String,
        risk: RiskClassification,
        reversibility: Reversibility,
        requestedDurationSeconds: Int64? = nil,
        originalProviderPayload: JSONValue,
        confidence: ApprovalEligibleConfidence,
        createdAt: Int64,
        expiresAt: Int64? = nil
    ) {
        self.id = id
        self.agent = agent
        self.projectID = projectID
        self.sessionID = sessionID
        self.tool = tool
        self.exactAction = exactAction
        self.explanation = explanation
        self.files = files
        self.domains = domains
        self.workingDirectory = workingDirectory
        self.risk = risk
        self.reversibility = reversibility
        self.requestedDurationSeconds = requestedDurationSeconds
        self.originalProviderPayload = originalProviderPayload
        self.confidence = confidence
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Whether the request is past its decision deadline at `now`
    /// (explicit `expiresAt` wins; otherwise the configurable default TTL
    /// from `createdAt` applies).
    public func isExpired(
        at now: Int64,
        defaultTTLMilliseconds: Int64 = ApprovalRequest.defaultTTLMilliseconds
    ) -> Bool {
        let deadline = expiresAt ?? createdAt + defaultTTLMilliseconds
        return deadline <= now
    }
}

/// A decision on an approval request (§15.1 choice + metadata).
public struct ApprovalDecision: Sendable, Equatable {
    public let choice: ApprovalChoice
    /// Required for `.allowCommandPatternInProject`; nil otherwise (§15.1).
    public let commandPattern: String?
    /// Unix ms.
    public let decidedAt: Int64

    /// - Throws: `ApprovalError.missingCommandPattern` when the choice
    ///   requires a pattern and none (or an empty one) is given.
    public init(choice: ApprovalChoice, commandPattern: String? = nil, decidedAt: Int64) throws {
        if choice == .allowCommandPatternInProject {
            guard let commandPattern, !commandPattern.isEmpty else {
                throw ApprovalError.missingCommandPattern
            }
        }
        self.choice = choice
        self.commandPattern = commandPattern
        self.decidedAt = decidedAt
    }
}

/// The stored outcome of resolving an approval request. On duplicate or
/// retried resolves (including after reconnect, §9) the resolver returns
/// the ORIGINAL outcome with `wasAlreadyResolved == true` and never
/// re-applies a decision.
public struct ApprovalResolution: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let requestID: ApprovalRequestID
    public let decision: ApprovalDecision
    /// True when this value reports a previously-applied decision rather
    /// than a newly-applied one (§9 idempotency).
    public let wasAlreadyResolved: Bool
    /// True when the request ran past its TTL and resolved to the terminal
    /// EXPIRED state (§15.3). The carried decision is a recording artifact
    /// (deny), never an applied authorization; later decisions are rejected.
    public let expired: Bool

    public init(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        wasAlreadyResolved: Bool,
        expired: Bool = false
    ) {
        self.requestID = requestID
        self.decision = decision
        self.wasAlreadyResolved = wasAlreadyResolved
        self.expired = expired
    }
}

public enum ApprovalError: Error, Equatable {
    /// Resolve attempted for a requestID the resolver never registered.
    case unknownRequest(ApprovalRequestID)
    /// A different request was registered under an already-used id.
    case duplicateRegistration(ApprovalRequestID)
    /// `.allowCommandPatternInProject` without a command pattern.
    case missingCommandPattern
    /// The request is in the terminal expired state — no decision,
    /// however timely it claims to be, can land after the TTL.
    case requestExpired(ApprovalRequestID)
}
