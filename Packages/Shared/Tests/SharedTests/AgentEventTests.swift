//
//  AgentEventTests.swift
//  SharedTests — AgentDeck
//
//  Event model tests: every payload case round-trips through the wire
//  form with its payloadV; unknown versions and unknown kinds are hard
//  errors; confidence gates approval surfaces; cursor derivation.
//

import Foundation
import Testing
@testable import Shared

@Suite("agent event model")
struct AgentEventTests {
    private let toolCallID = ToolCallID(uuid: UUID(uuidString: "99999999-8888-7777-6666-555555555555") ?? UUID())

    private func allPayloads() throws -> [AgentEventPayload] {
        let confidence = try #require(ApprovalEligibleConfidence(.versionedStream))
        let request = ApprovalRequest(
            id: .random(),
            agent: try #require(AgentIdentifier("com.example.adapter")),
            projectID: .random(),
            sessionID: .random(),
            tool: "shell",
            exactAction: "make build",
            explanation: "Build the project.",
            files: ["Makefile"],
            domains: [],
            workingDirectory: "/Users/test/project",
            risk: .low,
            reversibility: .reversible,
            requestedDurationSeconds: 300,
            originalProviderPayload: .object([("raw", .string("opaque provider blob"))]),
            confidence: confidence,
            createdAt: 1_752_793_200_000
        )
        let decision = try ApprovalDecision(
            choice: .allowCommandPatternInProject, commandPattern: "make *", decidedAt: 1_752_793_200_100
        )
        return [
            .stateChanged(SessionStateChange(from: .starting, to: .thinking)),
            .messageText(MessageText(role: .agent, text: "Working on it — héllo 😀")),
            .toolCallStarted(ToolCall(id: toolCallID, name: "read_file", summary: "Read SPEC.md")),
            .toolCallFinished(ToolCallResult(id: toolCallID, succeeded: true, summary: "Read 523 lines")),
            .commandStarted(CommandStart(id: toolCallID, command: "swift test", workingDirectory: "/tmp/pkg")),
            .commandFinished(CommandResult(id: toolCallID, exitCode: 0, durationMilliseconds: 4_200, outputSummary: "43 passed")),
            .commandFinished(CommandResult(id: toolCallID, exitCode: nil, durationMilliseconds: 10, outputSummary: "killed")),
            .fileOperation(FileOperation(kind: .modify, path: "Sources/main.swift")),
            .fileOperation(FileOperation(kind: .rename, path: "a.swift → b.swift")),
            .diffAvailable(DiffSummary(filesChanged: 3, additions: 120, deletions: 45)),
            .approvalRequested(request),
            .approvalResolved(ApprovalResolution(requestID: request.id, decision: decision, wasAlreadyResolved: false)),
            .waitingForUser(UserQuestion(question: "Which target should I build?")),
            .plan(PlanUpdate(summary: "Migrate the parser", steps: ["read", "rewrite", "test"])),
            .fileSearch(FileSearchResult(query: "Parser", matches: ["Sources/Parser.swift"])),
            .build(BuildReport(succeeded: true, summary: "Build finished in 12 s")),
            .test(TestReport(succeeded: false, passedCount: 41, failedCount: 2, summary: "2 failures")),
            .warning(AgentWarning(message: "Context window nearly full")),
            .completed(CompletionResult(succeeded: true, summary: "All done.")),
            .failed(AgentErrorInfo(code: "adapter.parse", message: "stream ended mid-frame", recovery: .retry)),
            .rawOutput(RawOutput(text: "\u{1B}[32mok\u{1B}[0m", reason: "PTY heuristic parse below confidence floor")),
            .transport(TransportNotice(
                code: .eventGap,
                message: "Event persistence cap reached; later events were not stored.",
                metadata: .object([("droppedCount", .int(17))])
            ))
        ]
    }

    @Test("every payload case round-trips through the wire form with its payloadV")
    func payloadRoundTrips() throws {
        let payloads = try allPayloads()
        #expect(payloads.count == 22, "new payload cases must be added to this test")
        var seenKinds = Set<String>()
        for payload in payloads {
            let wire = payload.toJSONValue()
            #expect(throws: Never.self) { _ = try wire.intField("payloadV") }
            let decoded = try AgentEventPayload(kind: payload.kind, data: wire)
            #expect(decoded == payload, "\(payload.kind) did not round-trip")
            seenKinds.insert(payload.kind)
        }
        #expect(seenKinds.count == 20, "each case has a unique wire kind")
    }

    @Test("unknown payload versions are hard errors, never guesses")
    func unknownVersionRejected() {
        let future: JSONValue = .object([
            ("payloadV", .int(2)),
            ("role", .string("agent")),
            ("text", .string("hi"))
        ])
        #expect(throws: JSONValueDecodingError.unsupportedPayloadVersion(found: 2, supported: 1)) {
            _ = try MessageText(jsonValue: future)
        }
        #expect(throws: JSONValueDecodingError.self) {
            _ = try AgentEventPayload(kind: "inventedByAFuturePeer", data: .object([:]))
        }
    }

    @Test("full event round-trips; cursor derives from the sequence")
    func eventRoundTrip() throws {
        let sessionID = SessionID.random()
        let event = AgentEvent(
            sessionID: sessionID,
            agent: try #require(AgentIdentifier("com.example.adapter")),
            sequence: 41,
            timestamp: 1_752_793_200_000,
            confidence: .ptyHeuristic,
            payload: .rawOutput(RawOutput(text: "raw", reason: "test"))
        )
        let decoded = try AgentEvent(jsonValue: event.toJSONValue())
        #expect(decoded == event)
        #expect(event.cursor == EventCursor(sessionID: sessionID, lastEventSequence: 41))
    }

    @Test("§10.4: events below 0.7 are flagged uncertain and not approval-eligible")
    func confidenceGatingOnEvents() throws {
        func event(_ confidence: EventConfidence) throws -> AgentEvent {
            AgentEvent(
                sessionID: .random(),
                agent: try #require(AgentIdentifier("com.example.adapter")),
                sequence: 1,
                timestamp: 0,
                confidence: confidence,
                payload: .messageText(MessageText(role: .agent, text: "x"))
            )
        }
        #expect(try event(.native).isApprovalEligible)
        #expect(try event(.versionedStream).isApprovalEligible)
        let heuristic = try event(.ptyHeuristic)
        #expect(!heuristic.isApprovalEligible)
        let unparsed = try event(.unknown)
        #expect(!unparsed.isApprovalEligible)
        #expect(heuristic.confidence.requiresUncertaintyIndicator)
    }

    @Test("an event carrying an approval request embeds a fully-formed §15.3 request")
    func approvalEvent() throws {
        let payloads = try allPayloads()
        guard case .approvalRequested(let request)? = payloads.first(where: {
            if case .approvalRequested = $0 { return true }
            return false
        }) else {
            Issue.record("fixture missing approvalRequested case")
            return
        }
        #expect(request.risk == .low)
        #expect(request.confidence.confidence == .versionedStream)
        #expect(request.requestedDurationSeconds == 300)
        // The request's own confidence is type-gated ≥ 0.7 regardless of the
        // carrying event's confidence — the two levels are both enforced.
    }
}

@Suite("transport notices")
struct TransportNoticeTests {
    @Test("transport notice round-trips with code, message, and metadata")
    func roundTrip() throws {
        let notice = TransportNotice(
            code: .resumePage,
            message: "More history remains.",
            metadata: .object([("hasMore", .bool(true)), ("lastEventSequence", try JSONValue.u64(41))])
        )
        #expect(try TransportNotice(jsonValue: notice.toJSONValue()) == notice)
        #expect(try AgentEventPayload(kind: "transport", data: notice.toJSONValue()) == .transport(notice))
    }

    @Test("unknown notice codes decode tolerantly instead of throwing")
    func unknownCodeTolerated() throws {
        let future: JSONValue = .object([
            ("payloadV", .int(1)),
            ("code", .string("inventedByAFutureBuild")),
            ("message", .string("future notice")),
            ("metadata", .object([:]))
        ])
        let decoded = try TransportNotice(jsonValue: future)
        #expect(decoded.code == .unknown, "future codes degrade to .unknown, never crash a peer")
        #expect(decoded.message == "future notice")
        // Known codes still decode exactly.
        #expect(try TransportNoticeCode(jsonValue: .string("eventGap")) == .eventGap)
        #expect(try TransportNoticeCode(jsonValue: .string("resumePage")) == .resumePage)
    }

    @Test("new session activity states encode additively")
    func newStatesWire() throws {
        #expect(SessionActivityState.ready.toJSONValue() == .string("ready"))
        #expect(SessionActivityState.runningBuild.toJSONValue() == .string("runningBuild"))
        #expect(SessionActivityState.terminated.toJSONValue() == .string("terminated"))
        #expect(try SessionActivityState(jsonValue: .string("terminated")) == .terminated)
        // Older persisted values still decode (additive-only guarantee).
        #expect(try SessionActivityState(jsonValue: .string("thinking")) == .thinking)
        #expect(SessionActivityState.terminated.isTerminal)
        #expect(SessionActivityState.ready.isTerminal == false)
        #expect(SessionActivityState.runningBuild.isTerminal == false)
        #expect(SessionActivityState.workStates.contains(.ready))
        #expect(SessionActivityState.workStates.contains(.runningBuild))
        #expect(!SessionActivityState.workStates.contains(.terminated))
    }
}
