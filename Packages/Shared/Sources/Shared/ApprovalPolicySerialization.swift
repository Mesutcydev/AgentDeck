//
//  ApprovalPolicySerialization.swift
//  Shared — AgentDeck
//
//  Wire/storage JSONValue forms for Phase 8 approval policy models.
//

import Foundation

extension ApprovalRule: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let id = "id"
        static let choice = "choice"
        static let projectID = "projectID"
        static let sessionID = "sessionID"
        static let tool = "tool"
        static let commandPattern = "commandPattern"
        static let explanation = "explanation"
        static let createdFromRequestID = "createdFromRequestID"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
        static let revokedAt = "revokedAt"
    }

    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: Self.payloadV)
        try self.init(
            id: jsonValue.nestedField(Field.id, as: ApprovalRuleID.self),
            choice: jsonValue.nestedField(Field.choice, as: ApprovalChoice.self),
            projectID: jsonValue.optionalNestedField(Field.projectID, as: ProjectID.self),
            sessionID: jsonValue.optionalNestedField(Field.sessionID, as: SessionID.self),
            tool: jsonValue.optionalStringField(Field.tool),
            commandPattern: jsonValue.optionalStringField(Field.commandPattern),
            explanation: jsonValue.stringField(Field.explanation),
            createdFromRequestID: jsonValue.optionalNestedField(Field.createdFromRequestID, as: ApprovalRequestID.self),
            createdAt: jsonValue.intField(Field.createdAt),
            expiresAt: jsonValue.optionalIntField(Field.expiresAt),
            revokedAt: jsonValue.optionalIntField(Field.revokedAt)
        )
    }

    public func toJSONValue() throws -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.id, id.toJSONValue()),
            (Field.choice, choice.toJSONValue()),
            (Field.explanation, .string(explanation)),
            (Field.createdAt, .int(createdAt))
        ]
        if let projectID {
            pairs.append((Field.projectID, projectID.toJSONValue()))
        }
        if let sessionID {
            pairs.append((Field.sessionID, sessionID.toJSONValue()))
        }
        if let tool {
            pairs.append((Field.tool, .string(tool)))
        }
        if let commandPattern {
            pairs.append((Field.commandPattern, .string(commandPattern)))
        }
        if let createdFromRequestID {
            pairs.append((Field.createdFromRequestID, createdFromRequestID.toJSONValue()))
        }
        if let expiresAt {
            pairs.append((Field.expiresAt, .int(expiresAt)))
        }
        if let revokedAt {
            pairs.append((Field.revokedAt, .int(revokedAt)))
        }
        return .object(pairs)
    }
}

extension ApprovalAuditEntry: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let id = "id"
        static let requestID = "requestID"
        static let sessionID = "sessionID"
        static let ruleID = "ruleID"
        static let eventKind = "eventKind"
        static let summary = "summary"
        static let metadata = "metadata"
        static let createdAt = "createdAt"
    }

    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: Self.payloadV)
        try self.init(
            id: jsonValue.nestedField(Field.id, as: ApprovalAuditEntryID.self),
            requestID: jsonValue.optionalNestedField(Field.requestID, as: ApprovalRequestID.self),
            sessionID: jsonValue.optionalNestedField(Field.sessionID, as: SessionID.self),
            ruleID: jsonValue.optionalNestedField(Field.ruleID, as: ApprovalRuleID.self),
            eventKind: jsonValue.nestedField(Field.eventKind, as: ApprovalAuditEventKind.self),
            summary: jsonValue.stringField(Field.summary),
            metadata: jsonValue.requiredField(Field.metadata),
            createdAt: jsonValue.intField(Field.createdAt)
        )
    }

    public func toJSONValue() throws -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.id, id.toJSONValue()),
            (Field.eventKind, eventKind.toJSONValue()),
            (Field.summary, .string(summary)),
            (Field.metadata, metadata),
            (Field.createdAt, .int(createdAt))
        ]
        if let requestID {
            pairs.append((Field.requestID, requestID.toJSONValue()))
        }
        if let sessionID {
            pairs.append((Field.sessionID, sessionID.toJSONValue()))
        }
        if let ruleID {
            pairs.append((Field.ruleID, ruleID.toJSONValue()))
        }
        return .object(pairs)
    }
}
