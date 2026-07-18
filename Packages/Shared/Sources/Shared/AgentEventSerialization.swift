//
//  AgentEventSerialization.swift
//  Shared — AgentDeck
//
//  Wire (JSONValue) forms of the event model. Every payload object carries
//  `payloadV` (§9); unknown versions are hard errors, never guesses
//  (Constitution #2).
//

import Foundation

/// Shared decoding helper: reads and validates `payloadV` for a payload type.
func requirePayloadV(_ jsonValue: JSONValue, supported: Int64) throws {
    let found = try jsonValue.intField("payloadV")
    guard found == supported else {
        throw JSONValueDecodingError.unsupportedPayloadVersion(found: found, supported: supported)
    }
}

extension AgentEvent: JSONValueConvertible {
    private enum Field {
        static let id = "id"
        static let sessionID = "sessionID"
        static let agent = "agent"
        static let sequence = "sequence"
        static let ts = "ts"
        static let confidence = "confidence"
        static let kind = "kind"
        static let data = "data"
    }

    public init(jsonValue: JSONValue) throws {
        self.init(
            id: try jsonValue.nestedField(Field.id, as: EventID.self),
            sessionID: try jsonValue.nestedField(Field.sessionID, as: SessionID.self),
            agent: try jsonValue.nestedField(Field.agent, as: AgentIdentifier.self),
            sequence: try jsonValue.u64Field(Field.sequence),
            timestamp: try jsonValue.intField(Field.ts),
            confidence: try jsonValue.nestedField(Field.confidence, as: EventConfidence.self),
            payload: try AgentEventPayload(
                kind: jsonValue.stringField(Field.kind),
                data: jsonValue.requiredField(Field.data)
            )
        )
    }

    public func toJSONValue() throws -> JSONValue {
        .object([
            (Field.id, id.toJSONValue()),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.agent, agent.toJSONValue()),
            (Field.sequence, try JSONValue.u64(sequence)),
            (Field.ts, .int(timestamp)),
            (Field.confidence, confidence.toJSONValue()),
            (Field.kind, .string(payload.kind)),
            (Field.data, payload.toJSONValue())
        ])
    }
}

extension AgentEventPayload: JSONValueConvertible {
    public init(kind: String, data: JSONValue) throws {
        switch kind {
        case "stateChanged":
            self = .stateChanged(try SessionStateChange(jsonValue: data))
        case "messageText":
            self = .messageText(try MessageText(jsonValue: data))
        case "toolCallStarted":
            self = .toolCallStarted(try ToolCall(jsonValue: data))
        case "toolCallFinished":
            self = .toolCallFinished(try ToolCallResult(jsonValue: data))
        case "commandStarted":
            self = .commandStarted(try CommandStart(jsonValue: data))
        case "commandFinished":
            self = .commandFinished(try CommandResult(jsonValue: data))
        case "fileOperation":
            self = .fileOperation(try FileOperation(jsonValue: data))
        case "diffAvailable":
            self = .diffAvailable(try DiffSummary(jsonValue: data))
        case "approvalRequested":
            self = .approvalRequested(try ApprovalRequest(jsonValue: data))
        case "approvalResolved":
            self = .approvalResolved(try ApprovalResolution(jsonValue: data))
        case "waitingForUser":
            self = .waitingForUser(try UserQuestion(jsonValue: data))
        case "plan":
            self = .plan(try PlanUpdate(jsonValue: data))
        case "fileSearch":
            self = .fileSearch(try FileSearchResult(jsonValue: data))
        case "build":
            self = .build(try BuildReport(jsonValue: data))
        case "test":
            self = .test(try TestReport(jsonValue: data))
        case "warning":
            self = .warning(try AgentWarning(jsonValue: data))
        case "completed":
            self = .completed(try CompletionResult(jsonValue: data))
        case "failed":
            self = .failed(try AgentErrorInfo(jsonValue: data))
        case "rawOutput":
            self = .rawOutput(try RawOutput(jsonValue: data))
        case "transport":
            self = .transport(try TransportNotice(jsonValue: data))
        default:
            throw JSONValueDecodingError.invalidValue(
                field: "kind", reason: "unknown event payload kind '\(kind)'"
            )
        }
    }

    public init(jsonValue: JSONValue) throws {
        try self.init(
            kind: jsonValue.stringField("kind"),
            data: jsonValue.requiredField("data")
        )
    }

    public func toJSONValue() -> JSONValue {
        switch self {
        case .stateChanged(let payload): payload.toJSONValue()
        case .messageText(let payload): payload.toJSONValue()
        case .toolCallStarted(let payload): payload.toJSONValue()
        case .toolCallFinished(let payload): payload.toJSONValue()
        case .commandStarted(let payload): payload.toJSONValue()
        case .commandFinished(let payload): payload.toJSONValue()
        case .fileOperation(let payload): payload.toJSONValue()
        case .diffAvailable(let payload): payload.toJSONValue()
        case .approvalRequested(let payload): payload.toJSONValue()
        case .approvalResolved(let payload): payload.toJSONValue()
        case .waitingForUser(let payload): payload.toJSONValue()
        case .plan(let payload): payload.toJSONValue()
        case .fileSearch(let payload): payload.toJSONValue()
        case .build(let payload): payload.toJSONValue()
        case .test(let payload): payload.toJSONValue()
        case .warning(let payload): payload.toJSONValue()
        case .completed(let payload): payload.toJSONValue()
        case .failed(let payload): payload.toJSONValue()
        case .rawOutput(let payload): payload.toJSONValue()
        case .transport(let payload): payload.toJSONValue()
        }
    }
}

// MARK: - Payload conformances

extension SessionStateChange: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: SessionStateChange.payloadV)
        self.init(
            from: try jsonValue.nestedField("from", as: SessionActivityState.self),
            to: try jsonValue.nestedField("to", as: SessionActivityState.self)
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(SessionStateChange.payloadV)),
            ("from", from.toJSONValue()),
            ("to", to.toJSONValue())
        ])
    }
}

extension MessageText: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: MessageText.payloadV)
        self.init(
            role: try jsonValue.nestedField("role", as: MessageRole.self),
            text: try jsonValue.stringField("text")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(MessageText.payloadV)),
            ("role", role.toJSONValue()),
            ("text", .string(text))
        ])
    }
}

extension ToolCall: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: ToolCall.payloadV)
        self.init(
            id: try jsonValue.nestedField("id", as: ToolCallID.self),
            name: try jsonValue.stringField("name"),
            summary: try jsonValue.stringField("summary")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(ToolCall.payloadV)),
            ("id", id.toJSONValue()),
            ("name", .string(name)),
            ("summary", .string(summary))
        ])
    }
}

extension ToolCallResult: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: ToolCallResult.payloadV)
        self.init(
            id: try jsonValue.nestedField("id", as: ToolCallID.self),
            succeeded: try jsonValue.boolField("succeeded"),
            summary: try jsonValue.stringField("summary")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(ToolCallResult.payloadV)),
            ("id", id.toJSONValue()),
            ("succeeded", .bool(succeeded)),
            ("summary", .string(summary))
        ])
    }
}

extension CommandStart: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: CommandStart.payloadV)
        self.init(
            id: try jsonValue.nestedField("id", as: ToolCallID.self),
            command: try jsonValue.stringField("command"),
            workingDirectory: try jsonValue.stringField("workingDirectory")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(CommandStart.payloadV)),
            ("id", id.toJSONValue()),
            ("command", .string(command)),
            ("workingDirectory", .string(workingDirectory))
        ])
    }
}

extension CommandResult: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: CommandResult.payloadV)
        self.init(
            id: try jsonValue.nestedField("id", as: ToolCallID.self),
            exitCode: try jsonValue.optionalIntField("exitCode"),
            durationMilliseconds: try jsonValue.intField("durationMilliseconds"),
            outputSummary: try jsonValue.stringField("outputSummary")
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("payloadV", .int(CommandResult.payloadV)),
            ("id", id.toJSONValue()),
            ("durationMilliseconds", .int(durationMilliseconds)),
            ("outputSummary", .string(outputSummary))
        ]
        if let exitCode {
            pairs.append(("exitCode", .int(exitCode)))
        }
        return .object(pairs)
    }
}

extension FileOperation: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: FileOperation.payloadV)
        self.init(
            kind: try jsonValue.nestedField("kind", as: FileOperationKind.self),
            path: try jsonValue.stringField("path")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(FileOperation.payloadV)),
            ("kind", kind.toJSONValue()),
            ("path", .string(path))
        ])
    }
}

extension DiffSummary: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: DiffSummary.payloadV)
        self.init(
            filesChanged: try jsonValue.intField("filesChanged"),
            additions: try jsonValue.intField("additions"),
            deletions: try jsonValue.intField("deletions")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(DiffSummary.payloadV)),
            ("filesChanged", .int(filesChanged)),
            ("additions", .int(additions)),
            ("deletions", .int(deletions))
        ])
    }
}

extension UserQuestion: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: UserQuestion.payloadV)
        self.init(question: try jsonValue.stringField("question"))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(UserQuestion.payloadV)),
            ("question", .string(question))
        ])
    }
}

extension CompletionResult: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: CompletionResult.payloadV)
        self.init(
            succeeded: try jsonValue.boolField("succeeded"),
            summary: try jsonValue.stringField("summary")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(CompletionResult.payloadV)),
            ("succeeded", .bool(succeeded)),
            ("summary", .string(summary))
        ])
    }
}

extension AgentErrorInfo: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: AgentErrorInfo.payloadV)
        self.init(
            code: try jsonValue.stringField("code"),
            message: try jsonValue.stringField("message"),
            recovery: try jsonValue.nestedField("recovery", as: RecoveryAction.self)
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(AgentErrorInfo.payloadV)),
            ("code", .string(code)),
            ("message", .string(message)),
            ("recovery", recovery.toJSONValue())
        ])
    }
}

extension RawOutput: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: RawOutput.payloadV)
        self.init(
            text: try jsonValue.stringField("text"),
            reason: try jsonValue.stringField("reason")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(RawOutput.payloadV)),
            ("text", .string(text)),
            ("reason", .string(reason))
        ])
    }
}

extension PlanUpdate: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PlanUpdate.payloadV)
        self.init(
            summary: try jsonValue.stringField("summary"),
            steps: try jsonValue.optionalStringArrayField("steps") ?? []
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(PlanUpdate.payloadV)),
            ("summary", .string(summary)),
            ("steps", .array(steps.map { .string($0) }))
        ])
    }
}

extension FileSearchResult: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: FileSearchResult.payloadV)
        self.init(
            query: try jsonValue.stringField("query"),
            matches: try jsonValue.optionalStringArrayField("matches") ?? []
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(FileSearchResult.payloadV)),
            ("query", .string(query)),
            ("matches", .array(matches.map { .string($0) }))
        ])
    }
}

extension BuildReport: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: BuildReport.payloadV)
        self.init(
            succeeded: try jsonValue.boolField("succeeded"),
            summary: try jsonValue.stringField("summary")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(BuildReport.payloadV)),
            ("succeeded", .bool(succeeded)),
            ("summary", .string(summary))
        ])
    }
}

extension TestReport: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: TestReport.payloadV)
        self.init(
            succeeded: try jsonValue.boolField("succeeded"),
            passedCount: try jsonValue.intField("passedCount"),
            failedCount: try jsonValue.intField("failedCount"),
            summary: try jsonValue.stringField("summary")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(TestReport.payloadV)),
            ("succeeded", .bool(succeeded)),
            ("passedCount", .int(passedCount)),
            ("failedCount", .int(failedCount)),
            ("summary", .string(summary))
        ])
    }
}

extension AgentWarning: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: AgentWarning.payloadV)
        self.init(message: try jsonValue.stringField("message"))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(AgentWarning.payloadV)),
            ("message", .string(message))
        ])
    }
}

extension TransportNotice: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: TransportNotice.payloadV)
        self.init(
            code: try jsonValue.nestedField("code", as: TransportNoticeCode.self),
            message: try jsonValue.stringField("message"),
            metadata: jsonValue.optionalField("metadata") ?? .object([:])
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(TransportNotice.payloadV)),
            ("code", code.toJSONValue()),
            ("message", .string(message)),
            ("metadata", metadata)
        ])
    }
}

// SessionActivityState travels inside event payloads (stateChanged).
extension SessionActivityState: JSONValueConvertible {}
