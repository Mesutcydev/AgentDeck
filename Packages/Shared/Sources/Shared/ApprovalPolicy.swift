//
//  ApprovalPolicy.swift
//  Shared — AgentDeck
//
//  Phase 8 approval policy engine (§15): risk assessment, scoped persistent
//  rules, secure-confirmation gating for critical actions, and audit history.
//  The model remains intentionally incapable of representing unrestricted
//  global "always approve everything" behavior (Constitution #6).
//

import Foundation

public enum ApprovalPolicyError: Error, Equatable {
    case nonPersistableChoice(ApprovalChoice)
    case sessionRuleRequiresSessionID
    case commandPatternRequired
    case criticalApprovalRequiresSecureConfirmation
}

extension ApprovalChoice {
    public var persistsAsRule: Bool {
        switch self {
        case .deny, .allowOnce:
            false
        case .allowSession, .allowCommandPatternInProject, .allowReadOnlyActions:
            true
        }
    }
}

extension RiskClassification {
    public var severityRank: Int {
        switch self {
        case .informational: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .critical: 4
        case .unknown: 5
        }
    }

    public func moreSevere(than other: RiskClassification) -> RiskClassification {
        severityRank >= other.severityRank ? self : other
    }

    public var allowsRuleAutoApproval: Bool { severityRank <= RiskClassification.medium.severityRank }
}

public struct ApprovalRiskAssessment: Sendable, Equatable {
    public let classification: RiskClassification
    public let isReadOnly: Bool
    public let reasons: [String]

    public init(classification: RiskClassification, isReadOnly: Bool, reasons: [String]) {
        self.classification = classification
        self.isReadOnly = isReadOnly
        self.reasons = reasons
    }
}

public enum ApprovalRiskAssessor {
    private static let readOnlyTools = Set([
        "readfile", "glob", "rg", "listfiles", "list"
    ])
    private static let informationalShellPrefixes = [
        "git status",
        "pwd",
        "which ",
        "swift --version",
        "xcodebuild -version"
    ]
    private static let readOnlyShellPrefixes = informationalShellPrefixes + [
        "git diff",
        "git show",
        "ls",
        "du ",
        "wc ",
        "stat "
    ]
    /// Multi-word fragments matched against the WHITESPACE-NORMALIZED
    /// action (runs of spaces/tabs/newlines collapse to one space), so
    /// `rm  -rf` cannot slip past `rm -rf`.
    private static let criticalFragments = [
        "rm -rf",
        "rm -fr",
        "rm -r -f",
        "rm -f -r",
        "defaults write",
        "chmod 777"
    ]
    /// Single-token critical commands, matched token-wise so `sudo` at
    /// end-of-line (or before a pipe) cannot evade a trailing-space fragment.
    private static let criticalTokens: Set<String> = [
        "sudo", "launchctl", "security", "crontab", "systemsetup"
    ]
    private static let highFragments = [
        "git push --force",
        "git push -f",
        "npm install",
        "pnpm add",
        "yarn add",
        "brew install",
        "pip install",
        "bundle install",
        "docker push",
        "kubectl apply",
        "terraform apply"
    ]
    private static let highTokens: Set<String> = [
        "scp", "rsync"
    ]
    /// Shell names a pipe may feed (`curl x|sh` needs no spaces around `|`).
    private static let pipeTargetShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ash"
    ]
    private static let shellStartupNames = [
        ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile",
        ".config/fish/config.fish", "launchagents"
    ]

    /// Collapses every run of whitespace (spaces, tabs, newlines) to a
    /// single space and trims — the canonical form all matching runs on.
    private static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True when the action contains shell composition — pipes, redirects,
    /// command separators, or command substitution. Composed commands can
    /// hide arbitrary side effects behind an innocent first token, so they
    /// are never classified read-only (conservative, §15.4).
    private static func isShellComposed(_ normalizedAction: String) -> Bool {
        normalizedAction.contains("|")
            || normalizedAction.contains(";")
            || normalizedAction.contains(">")
            || normalizedAction.contains("<")
            || normalizedAction.contains("`")
            || normalizedAction.contains("$(")
            || normalizedAction.contains("&")
    }

    /// True when any pipe segment targets a shell (`curl x|sh`, `… | sudo sh`).
    private static func pipesIntoShell(_ normalizedAction: String) -> Bool {
        for segment in normalizedAction.split(separator: "|").dropFirst() {
            var tokens = segment.split(separator: " ").map(String.init)
            if tokens.first == "sudo" {
                tokens.removeFirst()
            }
            if let first = tokens.first, pipeTargetShells.contains(first) {
                return true
            }
        }
        return false
    }

    public static func assess(_ request: ApprovalRequest) -> ApprovalRiskAssessment {
        let action = request.exactAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAction = normalizeWhitespace(action).lowercased()
        let tokens = Set(normalizedAction.split(separator: " ").map(String.init))
        let lowerTool = request.tool.lowercased()
        let lowerFiles = request.files.map { $0.lowercased() }

        guard !action.isEmpty else {
            return ApprovalRiskAssessment(
                classification: .unknown,
                isReadOnly: false,
                reasons: ["The exact action is empty, so the request cannot be safely classified."]
            )
        }

        if shellStartupNames.contains(where: { name in
            lowerFiles.contains(where: { $0.contains(name) }) || normalizedAction.contains(name)
        }) {
            return ApprovalRiskAssessment(
                classification: .critical,
                isReadOnly: false,
                reasons: ["The request touches shell startup or persistent service configuration files."]
            )
        }

        if criticalFragments.contains(where: normalizedAction.contains)
            || !tokens.isDisjoint(with: criticalTokens) {
            return ApprovalRiskAssessment(
                classification: .critical,
                isReadOnly: false,
                reasons: ["The action includes a critical system-changing command."]
            )
        }

        if pipesIntoShell(normalizedAction) {
            return ApprovalRiskAssessment(
                classification: .critical,
                isReadOnly: false,
                reasons: ["The action pipes output into a shell and can execute downloaded or generated code."]
            )
        }

        if !request.domains.isEmpty {
            return ApprovalRiskAssessment(
                classification: .high,
                isReadOnly: false,
                reasons: ["The request reaches new network domains and must be reviewed in-app."]
            )
        }

        if highFragments.contains(where: normalizedAction.contains)
            || !tokens.isDisjoint(with: highTokens) {
            return ApprovalRiskAssessment(
                classification: .high,
                isReadOnly: false,
                reasons: ["The action installs, deploys, force-pushes, or exfiltrates data."]
            )
        }

        let composed = isShellComposed(normalizedAction)
        let isReadOnly =
            !composed &&
            (readOnlyTools.contains(lowerTool) ||
            readOnlyShellPrefixes.contains(where: { normalizedAction.hasPrefix($0) }))

        if isReadOnly, informationalShellPrefixes.contains(where: { normalizedAction.hasPrefix($0) }),
           request.files.isEmpty, request.domains.isEmpty {
            return ApprovalRiskAssessment(
                classification: .informational,
                isReadOnly: true,
                reasons: ["The action only inspects local state."]
            )
        }

        if isReadOnly {
            return ApprovalRiskAssessment(
                classification: .low,
                isReadOnly: true,
                reasons: ["The action appears read-only and does not modify project state."]
            )
        }

        if !request.files.isEmpty || lowerTool == "shell" || composed {
            let reason = composed
                ? "The action composes shell operators (pipes, redirects, or substitutions), so its full effect must be reviewed."
                : "The action changes project-local state but stays within the user workspace."
            return ApprovalRiskAssessment(
                classification: .medium,
                isReadOnly: false,
                reasons: [reason]
            )
        }

        return ApprovalRiskAssessment(
            classification: .unknown,
            isReadOnly: false,
            reasons: ["The action does not match a trusted risk heuristic and must be reviewed manually."]
        )
    }
}

extension ApprovalRequest {
    public var policyAssessment: ApprovalRiskAssessment {
        ApprovalRiskAssessor.assess(self)
    }

    public var effectiveRisk: RiskClassification {
        risk.moreSevere(than: policyAssessment.classification)
    }

    public var isReadOnlyOperation: Bool { policyAssessment.isReadOnly }
}

public struct ApprovalRule: Sendable, Equatable, Identifiable {
    public static let payloadV: Int64 = 1

    public let id: ApprovalRuleID
    public let choice: ApprovalChoice
    public let projectID: ProjectID?
    public let sessionID: SessionID?
    public let tool: String?
    public let commandPattern: String?
    public let explanation: String
    public let createdFromRequestID: ApprovalRequestID?
    public let createdAt: Int64
    public let expiresAt: Int64?
    public let revokedAt: Int64?

    public init(
        id: ApprovalRuleID = .random(),
        choice: ApprovalChoice,
        projectID: ProjectID? = nil,
        sessionID: SessionID? = nil,
        tool: String? = nil,
        commandPattern: String? = nil,
        explanation: String,
        createdFromRequestID: ApprovalRequestID? = nil,
        createdAt: Int64,
        expiresAt: Int64? = nil,
        revokedAt: Int64? = nil
    ) throws {
        guard choice.persistsAsRule else {
            throw ApprovalPolicyError.nonPersistableChoice(choice)
        }
        if choice == .allowSession, sessionID == nil {
            throw ApprovalPolicyError.sessionRuleRequiresSessionID
        }
        if choice == .allowCommandPatternInProject,
           commandPattern?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw ApprovalPolicyError.commandPatternRequired
        }
        self.id = id
        self.choice = choice
        self.projectID = projectID
        self.sessionID = sessionID
        self.tool = tool
        self.commandPattern = commandPattern
        self.explanation = explanation
        self.createdFromRequestID = createdFromRequestID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public func isExpired(at now: Int64) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public func isActive(at now: Int64) -> Bool {
        revokedAt == nil && !isExpired(at: now)
    }

    public var displayText: String { explanation }

    fileprivate func matches(
        request: ApprovalRequest,
        effectiveRisk: RiskClassification,
        at now: Int64
    ) -> Bool {
        guard isActive(at: now) else { return false }
        guard effectiveRisk.allowsRuleAutoApproval else { return false }
        if let projectID, projectID != request.projectID {
            return false
        }
        if let sessionID, sessionID != request.sessionID {
            return false
        }
        if let tool, tool.caseInsensitiveCompare(request.tool) != .orderedSame {
            return false
        }
        switch choice {
        case .allowSession:
            return true
        case .allowReadOnlyActions:
            return request.isReadOnlyOperation
        case .allowCommandPatternInProject:
            guard let commandPattern else { return false }
            return CommandPatternMatcher.matches(pattern: commandPattern, command: request.exactAction)
        case .deny, .allowOnce:
            return false
        }
    }

    fileprivate func decision(decidedAt: Int64) throws -> ApprovalDecision {
        try ApprovalDecision(
            choice: choice,
            commandPattern: choice == .allowCommandPatternInProject ? commandPattern : nil,
            decidedAt: decidedAt
        )
    }
}

private enum CommandPatternMatcher {
    static func matches(pattern: String, command: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regex = "^\(escaped)$"
        guard let expression = try? NSRegularExpression(pattern: regex) else {
            return false
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return expression.firstMatch(in: command, options: [], range: range) != nil
    }
}

public enum ApprovalAuditEventKind: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case requestReceived
    case resolutionRecorded
    case ruleCreated
    case ruleRevoked
    case autoApproved
    case secureConfirmationRequired
    case secureConfirmationSatisfied
    /// A request ran past its TTL and resolved to the terminal expired state.
    case requestExpired
}

public struct ApprovalAuditEntry: Sendable, Equatable, Identifiable {
    public static let payloadV: Int64 = 1

    public let id: ApprovalAuditEntryID
    public let requestID: ApprovalRequestID?
    public let sessionID: SessionID?
    public let ruleID: ApprovalRuleID?
    public let eventKind: ApprovalAuditEventKind
    public let summary: String
    public let metadata: JSONValue
    public let createdAt: Int64

    public init(
        id: ApprovalAuditEntryID = .random(),
        requestID: ApprovalRequestID? = nil,
        sessionID: SessionID? = nil,
        ruleID: ApprovalRuleID? = nil,
        eventKind: ApprovalAuditEventKind,
        summary: String,
        metadata: JSONValue = .object([:]),
        createdAt: Int64
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.ruleID = ruleID
        self.eventKind = eventKind
        self.summary = summary
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public enum ApprovalEvaluation: Sendable, Equatable {
    case manual(effectiveRisk: RiskClassification, explanation: String)
    case autoApproved(decision: ApprovalDecision, matchedRule: ApprovalRule, effectiveRisk: RiskClassification)
}

public actor ApprovalPolicyEngine {
    private let repository: any SessionRepository

    public init(repository: any SessionRepository) {
        self.repository = repository
    }

    public func evaluate(
        _ request: ApprovalRequest,
        at now: Int64 = Date.unixMillisecondsNow
    ) async throws -> ApprovalEvaluation {
        let assessment = request.policyAssessment
        let effectiveRisk = request.effectiveRisk

        try await insertAudit(ApprovalAuditEntry(
            requestID: request.id,
            sessionID: request.sessionID,
            eventKind: .requestReceived,
            summary: "Approval request received for \(request.tool).",
            metadata: .object([
                ("assessedRisk", assessment.classification.toJSONValue()),
                ("effectiveRisk", effectiveRisk.toJSONValue()),
                ("isReadOnly", .bool(assessment.isReadOnly))
            ]),
            createdAt: now
        ))

        let rules = try await repository.listApprovalRules(
            projectID: request.projectID,
            sessionID: request.sessionID
        )
        if effectiveRisk.allowsRuleAutoApproval,
           let matchedRule = rules.first(where: { $0.matches(request: request, effectiveRisk: effectiveRisk, at: now) }) {
            let decision = try matchedRule.decision(decidedAt: now)
            try await insertAudit(ApprovalAuditEntry(
                requestID: request.id,
                sessionID: request.sessionID,
                ruleID: matchedRule.id,
                eventKind: .autoApproved,
                summary: matchedRule.displayText,
                metadata: .object([
                    ("choice", matchedRule.choice.toJSONValue())
                ]),
                createdAt: now
            ))
            return .autoApproved(decision: decision, matchedRule: matchedRule, effectiveRisk: effectiveRisk)
        }

        if effectiveRisk.requiresSecureConfirmation {
            try await insertAudit(ApprovalAuditEntry(
                requestID: request.id,
                sessionID: request.sessionID,
                eventKind: .secureConfirmationRequired,
                summary: "Critical approval requires in-app secure confirmation.",
                metadata: .object([
                    ("effectiveRisk", effectiveRisk.toJSONValue())
                ]),
                createdAt: now
            ))
        }

        let explanation = assessment.reasons.joined(separator: " ")
        return .manual(effectiveRisk: effectiveRisk, explanation: explanation)
    }

    @discardableResult
    public func recordManualResolution(
        request: ApprovalRequest,
        decision: ApprovalDecision,
        usedSecureConfirmation: Bool,
        at now: Int64 = Date.unixMillisecondsNow
    ) async throws -> ApprovalResolution {
        let effectiveRisk = request.effectiveRisk
        if decision.choice.authorizes, effectiveRisk.requiresSecureConfirmation, !usedSecureConfirmation {
            throw ApprovalPolicyError.criticalApprovalRequiresSecureConfirmation
        }

        if decision.choice.authorizes, effectiveRisk.requiresSecureConfirmation, usedSecureConfirmation {
            try await insertAudit(ApprovalAuditEntry(
                requestID: request.id,
                sessionID: request.sessionID,
                eventKind: .secureConfirmationSatisfied,
                summary: "Critical approval passed device authentication.",
                createdAt: now
            ))
        }

        if let rule = try storedRule(for: request, decision: decision, at: now) {
            try await repository.insertApprovalRule(rule)
            try await insertAudit(ApprovalAuditEntry(
                requestID: request.id,
                sessionID: request.sessionID,
                ruleID: rule.id,
                eventKind: .ruleCreated,
                summary: rule.displayText,
                metadata: .object([
                    ("choice", rule.choice.toJSONValue())
                ]),
                createdAt: now
            ))
        }

        try await insertAudit(ApprovalAuditEntry(
            requestID: request.id,
            sessionID: request.sessionID,
            eventKind: .resolutionRecorded,
            summary: "Approval resolved with \(decision.choice.rawValue).",
            metadata: .object([
                ("choice", decision.choice.toJSONValue())
            ]),
            createdAt: now
        ))

        return ApprovalResolution(
            requestID: request.id,
            decision: decision,
            wasAlreadyResolved: false
        )
    }

    /// Records the terminal expiry of a request in the audit trail (§15.3
    /// TTL) — the honest record that no decision ever landed.
    public func recordExpiry(
        request: ApprovalRequest,
        at now: Int64 = Date.unixMillisecondsNow
    ) async throws {
        try await insertAudit(ApprovalAuditEntry(
            requestID: request.id,
            sessionID: request.sessionID,
            eventKind: .requestExpired,
            summary: "Approval request for \(request.tool) expired without a decision.",
            createdAt: now
        ))
    }

    public func revokeRule(
        _ rule: ApprovalRule,
        sessionID: SessionID? = nil,
        at now: Int64 = Date.unixMillisecondsNow
    ) async throws {
        try await repository.revokeApprovalRule(id: rule.id, revokedAt: now)
        try await insertAudit(ApprovalAuditEntry(
            sessionID: sessionID,
            ruleID: rule.id,
            eventKind: .ruleRevoked,
            summary: "Approval rule revoked: \(rule.displayText)",
            createdAt: now
        ))
    }

    private func storedRule(
        for request: ApprovalRequest,
        decision: ApprovalDecision,
        at now: Int64
    ) throws -> ApprovalRule? {
        switch decision.choice {
        case .deny, .allowOnce:
            return nil
        case .allowSession:
            return try ApprovalRule(
                choice: .allowSession,
                projectID: request.projectID,
                sessionID: request.sessionID,
                explanation: "Allow actions in this session until it ends.",
                createdFromRequestID: request.id,
                createdAt: now,
                expiresAt: nil
            )
        case .allowCommandPatternInProject:
            // Constitution #8: secrets must never reach approval_rules or
            // audit summaries — scrub the pattern BEFORE it persists.
            let pattern = Redactor.redact(decision.commandPattern ?? request.exactAction)
            return try ApprovalRule(
                choice: .allowCommandPatternInProject,
                projectID: request.projectID,
                sessionID: nil,
                tool: request.tool,
                commandPattern: pattern,
                explanation: "Allow `\(pattern)` commands in this project.",
                createdFromRequestID: request.id,
                createdAt: now
            )
        case .allowReadOnlyActions:
            return try ApprovalRule(
                choice: .allowReadOnlyActions,
                projectID: request.projectID,
                sessionID: nil,
                explanation: "Allow read-only actions in this project.",
                createdFromRequestID: request.id,
                createdAt: now
            )
        }
    }

    private func insertAudit(_ entry: ApprovalAuditEntry) async throws {
        try await repository.insertApprovalAuditEntry(entry)
    }
}
