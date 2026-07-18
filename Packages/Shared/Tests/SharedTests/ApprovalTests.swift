//
//  ApprovalTests.swift
//  SharedTests — AgentDeck
//
//  Approval model tests: §15.1 choices, §15.4 risk, §15.3 request
//  contents, §10.4 confidence gating at the type level, §9 idempotent
//  resolve semantics, wire round-trips.
//

import Foundation
import Testing
@testable import Shared

@Suite("approval model")
struct ApprovalModelTests {
    private func makeRequest(
        risk: RiskClassification = .medium,
        confidence: EventConfidence = .native
    ) throws -> ApprovalRequest {
        ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "rm -rf ./build",
            explanation: "Remove the build directory to free disk space.",
            files: ["./build"],
            domains: [],
            workingDirectory: "/Users/test/project",
            risk: risk,
            reversibility: .irreversible,
            requestedDurationSeconds: nil,
            originalProviderPayload: .object([("payloadV", .int(1))]),
            confidence: try #require(ApprovalEligibleConfidence(confidence)),
            createdAt: 1_752_793_200_000
        )
    }

    @Test("§15.1: the v1 choice set is exactly the five scoped decisions")
    func v1Choices() {
        #expect(Set(ApprovalChoice.allCases) == [
            .deny, .allowOnce, .allowSession, .allowCommandPatternInProject, .allowReadOnlyActions
        ])
        // No unrestricted global auto-approval case exists (Constitution #6) —
        // if one is ever added, the count above fails loudly.
    }

    @Test("§15.4: risk classification set and secure-confirmation flags")
    func riskClassifications() {
        #expect(Set(RiskClassification.allCases) == [
            .informational, .low, .medium, .high, .critical, .unknown
        ])
        #expect(RiskClassification.critical.requiresSecureConfirmation)
        #expect(!RiskClassification.high.requiresSecureConfirmation)
        #expect(RiskClassification.high.requiresOpeningApp)
        #expect(RiskClassification.unknown.requiresOpeningApp)
        #expect(!RiskClassification.low.requiresOpeningApp)
    }

    @Test("§10.4: confidence below 0.7 cannot construct an approval-eligible value")
    func confidenceGating() {
        #expect(ApprovalEligibleConfidence(.native) != nil)
        #expect(ApprovalEligibleConfidence(.versionedStream) != nil)
        #expect(ApprovalEligibleConfidence(.ptyHeuristic) == nil)
        #expect(ApprovalEligibleConfidence(.unknown) == nil)
        #expect(EventConfidence.ptyHeuristic.requiresUncertaintyIndicator)
        #expect(EventConfidence.unknown.requiresUncertaintyIndicator)
        #expect(!EventConfidence.native.requiresUncertaintyIndicator)
    }

    @Test("confidence encodes as integer basis points on the wire")
    func confidenceWire() throws {
        #expect(EventConfidence.native.toJSONValue() == .int(10_000))
        #expect(EventConfidence.versionedStream.toJSONValue() == .int(7_000))
        #expect(EventConfidence.ptyHeuristic.toJSONValue() == .int(4_000))
        #expect(EventConfidence.unknown.toJSONValue() == .int(0))
        #expect(try EventConfidence(jsonValue: .int(10_000)) == .native)
        #expect(throws: JSONValueDecodingError.self) {
            _ = try EventConfidence(jsonValue: .int(8_500))
        }
        // Decoding an approval request's confidence below 0.7 is rejected.
        #expect(throws: JSONValueDecodingError.self) {
            _ = try ApprovalEligibleConfidence(jsonValue: .int(4_000))
        }
    }

    @Test("allowCommandPatternInProject requires a pattern")
    func patternRequired() throws {
        #expect(throws: ApprovalError.missingCommandPattern) {
            _ = try ApprovalDecision(choice: .allowCommandPatternInProject, decidedAt: 0)
        }
        #expect(throws: ApprovalError.missingCommandPattern) {
            _ = try ApprovalDecision(choice: .allowCommandPatternInProject, commandPattern: "", decidedAt: 0)
        }
        let decision = try ApprovalDecision(
            choice: .allowCommandPatternInProject, commandPattern: "git status", decidedAt: 0
        )
        #expect(decision.commandPattern == "git status")
    }

    @Test("§15.3 request wire round-trip preserves every field")
    func requestRoundTrip() throws {
        let request = try makeRequest(risk: .high)
        let decoded = try ApprovalRequest(jsonValue: request.toJSONValue())
        #expect(decoded == request)
        // payloadV is present and version-pinned.
        #expect(try request.toJSONValue().intField("payloadV") == ApprovalRequest.payloadV)
        #expect(throws: JSONValueDecodingError.self) {
            _ = try ApprovalRequest(jsonValue: .object([("payloadV", .int(99))]))
        }
    }

    @Test("decision and resolution wire round-trips")
    func decisionResolutionRoundTrip() throws {
        let decision = try ApprovalDecision(choice: .allowOnce, decidedAt: 1_752_793_200_000)
        #expect(try ApprovalDecision(jsonValue: decision.toJSONValue()) == decision)

        let resolution = ApprovalResolution(requestID: .random(), decision: decision, wasAlreadyResolved: true)
        #expect(try ApprovalResolution(jsonValue: resolution.toJSONValue()) == resolution)
    }
}

@Suite("§9 idempotent approval resolution")
struct ApprovalResolverTests {
    /// Requests in this suite are pinned at createdAt = 1_752_793_200_000;
    /// the resolver clock is pinned one minute later so nothing is expired.
    private func makeResolver() -> ApprovalResolver {
        ApprovalResolver(nowProvider: { 1_752_793_200_000 + 60_000 })
    }

    private func registerRequest(in resolver: ApprovalResolver) async throws -> ApprovalRequest {
        let confidence = try #require(ApprovalEligibleConfidence(.native))
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "make test",
            explanation: "Run the test suite.",
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .reversible,
            originalProviderPayload: .object([:]),
            confidence: confidence,
            createdAt: 1_752_793_200_000
        )
        try await resolver.register(request)
        return request
    }

    @Test("a resolve applies once; duplicates return the original outcome")
    func idempotentResolve() async throws {
        let resolver = makeResolver()
        let request = try await registerRequest(in: resolver)

        let allow = try ApprovalDecision(choice: .allowOnce, decidedAt: 1_000)
        let first = try await resolver.resolve(requestID: request.id, decision: allow)
        #expect(first.wasAlreadyResolved == false)
        #expect(first.decision.choice == .allowOnce)

        // A retried resolve — even with a DIFFERENT decision — returns the
        // original outcome and never re-applies (§9).
        let deny = try ApprovalDecision(choice: .deny, decidedAt: 2_000)
        let duplicate = try await resolver.resolve(requestID: request.id, decision: deny)
        #expect(duplicate.wasAlreadyResolved == true)
        #expect(duplicate.decision.choice == .allowOnce, "original decision must win over the retry")

        let third = try await resolver.resolve(requestID: request.id, decision: deny)
        #expect(third.wasAlreadyResolved == true)
        #expect(third.decision.decidedAt == 1_000, "stored decision is untouched")
    }

    @Test("resolving an unknown request is an error, not a guess")
    func unknownRequest() async {
        let resolver = makeResolver()
        let unknownID = ApprovalRequestID.random()
        await #expect(throws: ApprovalError.unknownRequest(unknownID)) {
            _ = try await resolver.resolve(
                requestID: unknownID,
                decision: try ApprovalDecision(choice: .deny, decidedAt: 0)
            )
        }
    }

    @Test("re-registering the same request id is idempotent only when identical")
    func duplicateRegistration() async throws {
        let resolver = makeResolver()
        let request = try await registerRequest(in: resolver)
        // Identical re-registration: safe retry, no error.
        try await resolver.register(request)
        // A different request under the same id: data-integrity error.
        let different = ApprovalRequest(
            id: request.id,
            agent: request.agent,
            projectID: .random(), // differs
            sessionID: request.sessionID,
            tool: request.tool,
            exactAction: request.exactAction,
            explanation: request.explanation,
            workingDirectory: request.workingDirectory,
            risk: request.risk,
            reversibility: request.reversibility,
            originalProviderPayload: request.originalProviderPayload,
            confidence: request.confidence,
            createdAt: request.createdAt
        )
        await #expect(throws: ApprovalError.duplicateRegistration(request.id)) {
            try await resolver.register(different)
        }
    }

    @Test("pendingRequests lists only unresolved requests")
    func pending() async throws {
        let resolver = makeResolver()
        let first = try await registerRequest(in: resolver)
        let second = try await registerRequest(in: resolver)
        #expect(await resolver.pendingRequests.count == 2)
        _ = try await resolver.resolve(
            requestID: first.id,
            decision: try ApprovalDecision(choice: .allowOnce, decidedAt: 0)
        )
        let pending = await resolver.pendingRequests
        #expect(pending.count == 1)
        #expect(pending.first?.id == second.id)
    }
}

@Suite("§15.3 approval expiry")
struct ApprovalExpiryTests {
    private let now: Int64 = 1_752_793_200_000

    private func makeRequest(
        createdAt: Int64,
        expiresAt: Int64? = nil
    ) throws -> ApprovalRequest {
        ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "make test",
            explanation: "Run the test suite.",
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .reversible,
            originalProviderPayload: .object([:]),
            confidence: try #require(ApprovalEligibleConfidence(.native)),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    @Test("default TTL is five minutes; explicit expiresAt wins")
    func ttlComputation() throws {
        let plain = try makeRequest(createdAt: now)
        #expect(plain.expiresAt == nil)
        #expect(!plain.isExpired(at: now + 299_999))
        #expect(plain.isExpired(at: now + 300_000), "default 5-minute TTL trips at the boundary")

        let custom = try makeRequest(createdAt: now, expiresAt: now + 1_000)
        #expect(custom.isExpired(at: now + 1_000))
        #expect(!custom.isExpired(at: now + 999))

        let noDefault = try makeRequest(createdAt: now)
        #expect(noDefault.isExpired(at: now + 10_000, defaultTTLMilliseconds: 5_000),
                "the resolver's configured TTL overrides the static default")
    }

    @Test("expired requests and resolutions round-trip on the wire")
    func expiryWireRoundTrip() throws {
        let request = try makeRequest(createdAt: now, expiresAt: now + 1_000)
        #expect(try ApprovalRequest(jsonValue: request.toJSONValue()) == request)
        // A request without expiresAt decodes with nil (backward compatible).
        let plain = try makeRequest(createdAt: now)
        #expect(try ApprovalRequest(jsonValue: plain.toJSONValue()).expiresAt == nil)

        let decision = try ApprovalDecision(choice: .deny, decidedAt: now)
        let expired = ApprovalResolution(requestID: .random(), decision: decision, wasAlreadyResolved: false, expired: true)
        #expect(try ApprovalResolution(jsonValue: expired.toJSONValue()) == expired)
        // Older payloads without the expired flag decode as non-expired.
        let legacy = ApprovalResolution(requestID: .random(), decision: decision, wasAlreadyResolved: true)
        #expect(try ApprovalResolution(jsonValue: legacy.toJSONValue()).expired == false)
    }

    @Test("a request past its TTL resolves to terminal expired and rejects all later decisions")
    func expiryIsTerminal() async throws {
        let resolver = ApprovalResolver()
        let stale = try makeRequest(createdAt: now - 600_000) // 10 min old, TTL 5 min
        try await resolver.register(stale)

        await #expect(throws: ApprovalError.requestExpired(stale.id)) {
            _ = try await resolver.resolve(
                requestID: stale.id,
                decision: try ApprovalDecision(choice: .allowOnce, decidedAt: self.now),
                now: self.now
            )
        }
        // The terminal state was RECORDED.
        let recorded = await resolver.resolution(for: stale.id)
        #expect(recorded?.expired == true)
        #expect(recorded?.decision.choice == .deny, "expiry records a deny artifact, never an authorization")
        // Later decisions are rejected — the request is done, not just denied.
        await #expect(throws: ApprovalError.requestExpired(stale.id)) {
            _ = try await resolver.resolve(
                requestID: stale.id,
                decision: try ApprovalDecision(choice: .allowOnce, decidedAt: self.now + 1),
                now: self.now + 1
            )
        }
        #expect(await resolver.pendingRequests.isEmpty)
    }

    @Test("a live request resolves normally and keeps §9 idempotency")
    func liveRequestUnaffected() async throws {
        let resolver = ApprovalResolver()
        let live = try makeRequest(createdAt: now)
        try await resolver.register(live)
        let decision = try ApprovalDecision(choice: .allowOnce, decidedAt: now + 1_000)
        let first = try await resolver.resolve(requestID: live.id, decision: decision, now: now + 1_000)
        #expect(!first.wasAlreadyResolved)
        #expect(!first.expired)
        let retry = try await resolver.resolve(requestID: live.id, decision: decision, now: now + 2_000)
        #expect(retry.wasAlreadyResolved, "decided (not expired) resolutions still replay the original")
    }

    @Test("sweep resolves every overdue pending request exactly once")
    func sweep() async throws {
        let resolver = ApprovalResolver()
        let staleFirst = try makeRequest(createdAt: now - 600_000)
        let staleSecond = try makeRequest(createdAt: now - 600_000)
        let live = try makeRequest(createdAt: now)
        for request in [staleFirst, staleSecond, live] {
            try await resolver.register(request)
        }
        let swept = try await resolver.sweepExpired(now: now)
        #expect(Set(swept.map(\.requestID)) == [staleFirst.id, staleSecond.id])
        #expect(swept.allSatisfy { $0.expired })
        // Re-sweeping is a no-op: terminal means terminal.
        #expect(try await resolver.sweepExpired(now: now + 1).isEmpty)
        #expect(await resolver.pendingRequests.map(\.id) == [live.id])
    }

    @Test("expireIfNeeded expires only overdue pending requests")
    func expireIfNeeded() async throws {
        let resolver = ApprovalResolver()
        let stale = try makeRequest(createdAt: now - 600_000)
        let live = try makeRequest(createdAt: now)
        try await resolver.register(stale)
        try await resolver.register(live)
        #expect(try await resolver.expireIfNeeded(requestID: live.id, now: now) == false)
        #expect(try await resolver.expireIfNeeded(requestID: stale.id, now: now) == true)
        #expect(try await resolver.expireIfNeeded(requestID: stale.id, now: now) == false, "already terminal")
        #expect(try await resolver.expireIfNeeded(requestID: .random(), now: now) == false, "unknown id is a no-op")
    }
}
