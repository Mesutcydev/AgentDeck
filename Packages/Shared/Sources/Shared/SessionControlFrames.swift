//
//  SessionControlFrames.swift
//  Shared — AgentDeck
//
//  §29 Phase 6 client→companion session control payloads (ADR-0013).
//

import Foundation

/// Client sends a prompt to an active session (§10.2).
public struct SessionPromptRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let sessionID: SessionID
    public let prompt: PromptInput

    public init(sessionID: SessionID, prompt: PromptInput) {
        self.sessionID = sessionID
        self.prompt = prompt
    }
}

extension SessionPromptRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let sessionID = "sessionID"
        static let prompt = "prompt"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.sessionID = try jsonValue.nestedField(Field.sessionID, as: SessionID.self)
        self.prompt = try jsonValue.nestedField(Field.prompt, as: PromptInput.self)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            (Field.payloadV, .int(Self.payloadV)),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.prompt, prompt.toJSONValue())
        ])
    }
}

/// Client requests interruption of an active session (§10.1 interrupt).
public struct SessionInterruptRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

extension SessionInterruptRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let sessionID = "sessionID"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.sessionID = try jsonValue.nestedField(Field.sessionID, as: SessionID.self)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            (Field.payloadV, .int(Self.payloadV)),
            (Field.sessionID, sessionID.toJSONValue())
        ])
    }
}

extension PromptInput: JSONValueConvertible {
    public static let payloadV: Int64 = 1

    private enum Field {
        static let payloadV = "payloadV"
        static let text = "text"
        static let attachments = "attachments"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        let text = try jsonValue.stringField(Field.text)
        let attachmentValues: [AttachmentReference]
        if let raw = jsonValue.optionalField(Field.attachments), let array = raw.arrayValue {
            attachmentValues = try array.map { try AttachmentReference(jsonValue: $0) }
        } else {
            attachmentValues = []
        }
        self.init(text: text, attachments: attachmentValues)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            (Field.payloadV, .int(Self.payloadV)),
            (Field.text, .string(text)),
            (Field.attachments, .array(attachments.map { $0.toJSONValue() }))
        ])
    }
}

extension AttachmentReference: JSONValueConvertible {
    public static let payloadV: Int64 = 1

    private enum Field {
        static let payloadV = "payloadV"
        static let id = "id"
        static let fileName = "fileName"
        static let byteCount = "byteCount"
        static let mimeType = "mimeType"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        let idText = try jsonValue.stringField(Field.id)
        guard let id = UUID(uuidString: idText) else {
            throw JSONValueDecodingError.invalidValue(field: Field.id, reason: "invalid UUID")
        }
        self.init(
            id: id,
            fileName: try jsonValue.stringField(Field.fileName),
            byteCount: try jsonValue.intField(Field.byteCount),
            mimeType: try jsonValue.optionalStringField(Field.mimeType)
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.id, .string(id.uuidString)),
            (Field.fileName, .string(fileName)),
            (Field.byteCount, .int(byteCount))
        ]
        if let mimeType {
            pairs.append((Field.mimeType, .string(mimeType)))
        }
        return .object(pairs)
    }
}
