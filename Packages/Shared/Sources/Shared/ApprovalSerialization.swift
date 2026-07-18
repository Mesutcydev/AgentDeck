//
//  ApprovalSerialization.swift
//  Shared — AgentDeck
//
//  Wire (JSONValue) forms of the approval model. Each payload carries
//  `payloadV` (SPEC §9: every payload type is independently versioned).
//

import Foundation

extension ApprovalRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let id = "id"
        static let agent = "agent"
        static let projectID = "projectID"
        static let sessionID = "sessionID"
        static let tool = "tool"
        static let exactAction = "exactAction"
        static let explanation = "explanation"
        static let files = "files"
        static let domains = "domains"
        static let workingDirectory = "workingDirectory"
        static let risk = "risk"
        static let reversibility = "reversibility"
        static let requestedDurationSeconds = "requestedDurationSeconds"
        static let originalProviderPayload = "originalProviderPayload"
        static let confidence = "confidence"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == ApprovalRequest.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(
                found: version, supported: ApprovalRequest.payloadV
            )
        }
        self.init(
            id: try jsonValue.nestedField(Field.id, as: ApprovalRequestID.self),
            agent: try jsonValue.nestedField(Field.agent, as: AgentIdentifier.self),
            projectID: try jsonValue.nestedField(Field.projectID, as: ProjectID.self),
            sessionID: try jsonValue.nestedField(Field.sessionID, as: SessionID.self),
            tool: try jsonValue.stringField(Field.tool),
            exactAction: try jsonValue.stringField(Field.exactAction),
            explanation: try jsonValue.stringField(Field.explanation),
            files: try jsonValue.optionalStringArrayField(Field.files) ?? [],
            domains: try jsonValue.optionalStringArrayField(Field.domains) ?? [],
            workingDirectory: try jsonValue.stringField(Field.workingDirectory),
            risk: try jsonValue.nestedField(Field.risk, as: RiskClassification.self),
            reversibility: try jsonValue.nestedField(Field.reversibility, as: Reversibility.self),
            requestedDurationSeconds: try jsonValue.optionalIntField(Field.requestedDurationSeconds),
            originalProviderPayload: try jsonValue.requiredField(Field.originalProviderPayload),
            confidence: try jsonValue.nestedField(Field.confidence, as: ApprovalEligibleConfidence.self),
            createdAt: try jsonValue.intField(Field.createdAt),
            // Optional on the wire: absent means the default TTL applies.
            expiresAt: try jsonValue.optionalIntField(Field.expiresAt)
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(ApprovalRequest.payloadV)),
            (Field.id, id.toJSONValue()),
            (Field.agent, agent.toJSONValue()),
            (Field.projectID, projectID.toJSONValue()),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.tool, .string(tool)),
            (Field.exactAction, .string(exactAction)),
            (Field.explanation, .string(explanation)),
            (Field.files, .array(files.map { .string($0) })),
            (Field.domains, .array(domains.map { .string($0) })),
            (Field.workingDirectory, .string(workingDirectory)),
            (Field.risk, risk.toJSONValue()),
            (Field.reversibility, reversibility.toJSONValue()),
            (Field.originalProviderPayload, originalProviderPayload),
            (Field.confidence, confidence.toJSONValue()),
            (Field.createdAt, .int(createdAt))
        ]
        if let requestedDurationSeconds {
            pairs.append((Field.requestedDurationSeconds, .int(requestedDurationSeconds)))
        }
        if let expiresAt {
            pairs.append((Field.expiresAt, .int(expiresAt)))
        }
        return .object(pairs)
    }
}

extension ApprovalDecision: JSONValueConvertible {
    private enum Field {
        static let choice = "choice"
        static let commandPattern = "commandPattern"
        static let decidedAt = "decidedAt"
    }

    public init(jsonValue: JSONValue) throws {
        try self.init(
            choice: jsonValue.nestedField(Field.choice, as: ApprovalChoice.self),
            commandPattern: jsonValue.optionalStringField(Field.commandPattern),
            decidedAt: jsonValue.intField(Field.decidedAt)
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.choice, choice.toJSONValue()),
            (Field.decidedAt, .int(decidedAt))
        ]
        if let commandPattern {
            pairs.append((Field.commandPattern, .string(commandPattern)))
        }
        return .object(pairs)
    }
}

extension ApprovalResolution: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let requestID = "requestID"
        static let decision = "decision"
        static let wasAlreadyResolved = "wasAlreadyResolved"
        static let expired = "expired"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == ApprovalResolution.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(
                found: version, supported: ApprovalResolution.payloadV
            )
        }
        self.init(
            requestID: try jsonValue.nestedField(Field.requestID, as: ApprovalRequestID.self),
            decision: try jsonValue.nestedField(Field.decision, as: ApprovalDecision.self),
            wasAlreadyResolved: try jsonValue.boolField(Field.wasAlreadyResolved),
            // Optional on the wire: absent means a decided (not expired) resolution.
            expired: jsonValue.optionalField(Field.expired) != nil
                ? try jsonValue.boolField(Field.expired)
                : false
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(ApprovalResolution.payloadV)),
            (Field.requestID, requestID.toJSONValue()),
            (Field.decision, decision.toJSONValue()),
            (Field.wasAlreadyResolved, .bool(wasAlreadyResolved))
        ]
        if expired {
            pairs.append((Field.expired, .bool(expired)))
        }
        return .object(pairs)
    }
}

/// Device → companion approval decision (§9 `approval.resolve`, Phase 6).
public struct ApprovalResolveRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let requestID: ApprovalRequestID
    public let sessionID: SessionID
    public let decision: ApprovalDecision
    public let usedSecureConfirmation: Bool

    public init(
        requestID: ApprovalRequestID,
        sessionID: SessionID,
        decision: ApprovalDecision,
        usedSecureConfirmation: Bool = false
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.decision = decision
        self.usedSecureConfirmation = usedSecureConfirmation
    }
}

extension ApprovalResolveRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let requestID = "requestID"
        static let sessionID = "sessionID"
        static let decision = "decision"
        static let usedSecureConfirmation = "usedSecureConfirmation"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        let usedSecureConfirmation =
            if jsonValue.optionalField(Field.usedSecureConfirmation) != nil {
                try jsonValue.boolField(Field.usedSecureConfirmation)
            } else {
                false
            }
        self.init(
            requestID: try jsonValue.nestedField(Field.requestID, as: ApprovalRequestID.self),
            sessionID: try jsonValue.nestedField(Field.sessionID, as: SessionID.self),
            decision: try jsonValue.nestedField(Field.decision, as: ApprovalDecision.self),
            usedSecureConfirmation: usedSecureConfirmation
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            (Field.payloadV, .int(Self.payloadV)),
            (Field.requestID, requestID.toJSONValue()),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.decision, decision.toJSONValue()),
            (Field.usedSecureConfirmation, .bool(usedSecureConfirmation))
        ])
    }
}
