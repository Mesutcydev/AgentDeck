//
//  RelayNotification.swift
//  Shared — AgentDeck
//
//  §14.3 notification relay payload: fixed minimal schema with a hard
//  ceiling on allowed fields. The relay never receives code, terminal
//  output, full prompts, or credentials.
//

import Foundation

/// Opaque APNs destination token registered by a paired iOS device.
public struct PushDestinationToken: Sendable, Hashable, Codable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        self.rawValue = trimmed
    }
}

/// §14.2 notification categories mapped to relay event types.
public enum RelayNotificationEventType: String, Sendable, CaseIterable, Codable {
    case approvalRequired = "approval_required"
    case agentQuestion = "agent_question"
    case sessionCompleted = "session_completed"
    case sessionFailed = "session_failed"
    case connectionLost = "connection_lost"
    case securityWarning = "security_warning"
}

/// Allowed §14.3 relay request fields only.
public struct RelayNotifyRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let destinationToken: PushDestinationToken
    public let eventType: RelayNotificationEventType
    public let sessionID: SessionID
    public let projectAlias: String?
    public let notificationText: String
    public let expiration: Int64
    public var signature: Data?

    public init(
        destinationToken: PushDestinationToken,
        eventType: RelayNotificationEventType,
        sessionID: SessionID,
        projectAlias: String?,
        notificationText: String,
        expiration: Int64,
        signature: Data? = nil
    ) {
        self.destinationToken = destinationToken
        self.eventType = eventType
        self.sessionID = sessionID
        self.projectAlias = projectAlias
        self.notificationText = notificationText
        self.expiration = expiration
        self.signature = signature
    }
}

public enum RelayNotificationError: Error, Equatable {
    case forbiddenField(String)
    case invalidPayload(String)
    case expired
    case signatureMissing
    case signatureInvalid
}

/// Validates that a JSON object contains only §14.3-allowed keys.
public enum RelayNotifyValidator {
    public static let allowedKeys: Set<String> = [
        "payloadV",
        "destinationToken",
        "eventType",
        "sessionID",
        "projectAlias",
        "notificationText",
        "expiration",
        "signature"
    ]

    /// Keys the relay must never accept (§14.3 hard ceiling).
    public static let forbiddenKeys: Set<String> = [
        "terminalOutput",
        "terminal_output",
        "sourceCode",
        "source_code",
        "prompt",
        "fullPrompt",
        "fileContents",
        "file_contents",
        "environment",
        "apiKey",
        "api_key",
        "command",
        "exactAction",
        "rawOutput"
    ]

    public static func validateJSONObject(_ object: [String: Any]) throws {
        for key in object.keys {
            if forbiddenKeys.contains(key) {
                throw RelayNotificationError.forbiddenField(key)
            }
            if !allowedKeys.contains(key) {
                throw RelayNotificationError.forbiddenField(key)
            }
        }
        guard let text = object["notificationText"] as? String else {
            throw RelayNotificationError.invalidPayload("notificationText required")
        }
        let redacted = Redactor.redact(text)
        if redacted != text {
            throw RelayNotificationError.invalidPayload("notificationText must be pre-redacted")
        }
    }

    public static func validate(_ request: RelayNotifyRequest, now: Int64 = Date.unixMillisecondsNow) throws {
        guard request.expiration >= now else {
            throw RelayNotificationError.expired
        }
        guard !request.notificationText.isEmpty else {
            throw RelayNotificationError.invalidPayload("notificationText empty")
        }
        guard request.notificationText.count <= 256 else {
            throw RelayNotificationError.invalidPayload("notificationText too long")
        }
        if let alias = request.projectAlias, alias.count > 64 {
            throw RelayNotificationError.invalidPayload("projectAlias too long")
        }
    }
}

extension RelayNotifyRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let destinationToken = "destinationToken"
        static let eventType = "eventType"
        static let sessionID = "sessionID"
        static let projectAlias = "projectAlias"
        static let notificationText = "notificationText"
        static let expiration = "expiration"
        static let signature = "signature"
    }

    public init(jsonValue: JSONValue) throws {
        guard case .object(let entries) = jsonValue else {
            throw JSONValueDecodingError.invalidValue(field: "root", reason: "object required")
        }
        var object: [String: Any] = [:]
        for (key, value) in entries {
            object[key] = value.foundationValue
        }
        try RelayNotifyValidator.validateJSONObject(object)

        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        guard let token = PushDestinationToken(try jsonValue.stringField(Field.destinationToken)) else {
            throw JSONValueDecodingError.invalidValue(field: Field.destinationToken, reason: "invalid token")
        }
        self.destinationToken = token
        self.eventType = try jsonValue.nestedField(Field.eventType, as: RelayNotificationEventType.self)
        self.sessionID = try jsonValue.nestedField(Field.sessionID, as: SessionID.self)
        self.projectAlias = try jsonValue.optionalStringField(Field.projectAlias)
        self.notificationText = try jsonValue.stringField(Field.notificationText)
        self.expiration = try jsonValue.intField(Field.expiration)
        if let signatureText = try jsonValue.optionalStringField(Field.signature) {
            guard let data = Data(base64Encoded: signatureText) else {
                throw JSONValueDecodingError.invalidValue(field: Field.signature, reason: "base64")
            }
            self.signature = data
        } else {
            self.signature = nil
        }
    }

    public func toJSONValue() throws -> JSONValue {
        var entries: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.destinationToken, .string(destinationToken.rawValue)),
            (Field.eventType, eventType.toJSONValue()),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.notificationText, .string(notificationText)),
            (Field.expiration, .int(expiration))
        ]
        if let projectAlias {
            entries.append((Field.projectAlias, .string(projectAlias)))
        }
        if let signature {
            entries.append((Field.signature, .string(signature.base64EncodedString())))
        }
        return .object(entries)
    }
}

extension RelayNotificationEventType: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = RelayNotificationEventType(rawValue: raw) else {
            throw JSONValueDecodingError.invalidValue(field: "eventType", reason: "unknown")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(rawValue) }
}

/// Builds pre-redacted relay payloads from structured agent events.
///
/// APNs text comes exclusively from the fixed templates below: agent
/// controlled free-form text (result summaries, error messages, tool
/// names) never reaches the notification body — only IDs, the event
/// category, and the risk classification. This removes the injection
/// surface the previous redact-then-interpolate approach relied on regex
/// to contain.
public enum RelayNotificationBuilder {
    public static func approvalRequiredText(risk: RiskClassification) -> String {
        String(localized: "Approval needed (\(risk.rawValue) risk). Open AgentDeck to review.")
    }

    public static func sessionCompletedText() -> String {
        String(localized: "Session completed. Open AgentDeck to review.")
    }

    public static func sessionFailedText(code: String) -> String {
        String(localized: "Session failed (\(code)). Open AgentDeck to review.")
    }

    public static func build(
        from event: AgentEvent,
        destinationToken: PushDestinationToken,
        projectAlias: String?,
        ttlSeconds: Int64 = 300
    ) -> RelayNotifyRequest? {
        let expiration = event.timestamp + ttlSeconds * 1000
        switch event.payload {
        case .approvalRequested(let request):
            return RelayNotifyRequest(
                destinationToken: destinationToken,
                eventType: .approvalRequired,
                sessionID: event.sessionID,
                projectAlias: projectAlias,
                notificationText: approvalRequiredText(risk: request.risk),
                expiration: expiration
            )
        case .completed:
            return RelayNotifyRequest(
                destinationToken: destinationToken,
                eventType: .sessionCompleted,
                sessionID: event.sessionID,
                projectAlias: projectAlias,
                notificationText: sessionCompletedText(),
                expiration: expiration
            )
        case .failed(let info):
            // `code` is an adapter-declared constant (e.g. "claude.exit"),
            // not free-form agent text; the free-form message is dropped.
            let code = info.code.isEmpty ? "unknown" : info.code
            return RelayNotifyRequest(
                destinationToken: destinationToken,
                eventType: .sessionFailed,
                sessionID: event.sessionID,
                projectAlias: projectAlias,
                notificationText: sessionFailedText(code: code),
                expiration: expiration
            )
        default:
            return nil
        }
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let entries): return Dictionary(uniqueKeysWithValues: entries.map { ($0, $1.foundationValue) })
        }
    }
}
