//
//  TerminalFrames.swift
//  Shared — AgentDeck
//
//  §9 terminal stream payloads (ADR-0012). Binary PTY bytes travel base64-
//  encoded inside signed frames — never parsed in business logic (§25).
//

import Foundation

private func decodeTerminalBase64(_ jsonValue: JSONValue, field: String) throws -> Data {
    let text = try jsonValue.stringField(field)
    guard let data = Data(base64Encoded: text) else {
        throw JSONValueDecodingError.invalidValue(field: field, reason: "not base64")
    }
    return data
}

public enum TerminalFramePayloadVersion: Int64, Sendable {
    case v1 = 1
}

/// Companion → device PTY output chunk.
public struct TerminalOutputPayload: Sendable, Equatable {
    public static let payloadV: Int64 = TerminalFramePayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var data: Data
    /// True when this chunk is replay scrollback during reattachment.
    public var isReplay: Bool

    public init(sessionID: SessionID, data: Data, isReplay: Bool = false) {
        self.sessionID = sessionID
        self.data = data
        self.isReplay = isReplay
    }
}

/// Device → companion PTY input chunk.
public struct TerminalInputPayload: Sendable, Equatable {
    public static let payloadV: Int64 = TerminalFramePayloadVersion.v1.rawValue

    public var sessionID: SessionID
    public var data: Data

    public init(sessionID: SessionID, data: Data) {
        self.sessionID = sessionID
        self.data = data
    }
}

extension TerminalOutputPayload: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let payloadV = try jsonValue.intField("payloadV")
        guard payloadV == Self.payloadV else {
            throw JSONValueDecodingError.invalidValue(field: "payloadV", reason: "unsupported")
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        let data = try decodeTerminalBase64(jsonValue, field: "data")
        let isReplay = try jsonValue.boolField("isReplay")
        self.init(sessionID: sessionID, data: data, isReplay: isReplay)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString)),
            ("data", .string(data.base64EncodedString())),
            ("isReplay", .bool(isReplay))
        ])
    }
}

extension TerminalInputPayload: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let payloadV = try jsonValue.intField("payloadV")
        guard payloadV == Self.payloadV else {
            throw JSONValueDecodingError.invalidValue(field: "payloadV", reason: "unsupported")
        }
        guard let sessionID = SessionID(try jsonValue.stringField("sessionID")) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "invalid")
        }
        let data = try decodeTerminalBase64(jsonValue, field: "data")
        self.init(sessionID: sessionID, data: data)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(Self.payloadV)),
            ("sessionID", .string(sessionID.wireString)),
            ("data", .string(data.base64EncodedString()))
        ])
    }
}
