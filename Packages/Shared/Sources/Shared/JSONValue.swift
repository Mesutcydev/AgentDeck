//
//  JSONValue.swift
//  Shared — AgentDeck
//
//  JSON value model for the §9 wire protocol. Deliberately has NO float
//  case: all frame numbers are integers (SPEC §9), which keeps the JCS
//  (RFC 8785) canonical encoding unambiguous and identical on both peers.
//

import Foundation

/// A JSON value restricted to the integer-only v1 wire subset (SPEC §9).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// Types that serialize to/from the integer-only `JSONValue` subset.
/// All wire payloads (§9 `payload`, each carrying `payloadV`) conform.
///
/// Encoding throws because UInt64 counters (seq/ack/event sequence) cannot
/// be represented above Int64.max on the integer-only wire; silently
/// clamping would corrupt monotonicity, so overflow is an explicit error
/// (data integrity, SPEC §5.4). Unreachable in practice — 2^63 frames per
/// direction cannot occur — but never silent.
public protocol JSONValueConvertible: Sendable {
    init(jsonValue: JSONValue) throws
    func toJSONValue() throws -> JSONValue
}

/// Errors thrown while decoding model types from `JSONValue`.
public enum JSONValueDecodingError: Error, Equatable {
    case missingField(String)
    case wrongType(field: String, expected: String)
    case invalidValue(field: String, reason: String)
    case integerOutOfRange(field: String)
    case unsupportedPayloadVersion(found: Int64, supported: Int64)
}

extension JSONValue {
    // MARK: - Typed probes

    public var isNull: Bool { self == .null }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    public var intValue: Int64? {
        guard case .int(let int) = self else { return nil }
        return int
    }

    public var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }

    // MARK: - Building

    /// Builds an object from pairs (order is not preserved; the canonical
    /// serializer sorts keys per RFC 8785).
    public static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }

    /// Encodes a UInt64 into the signed wire range. Throws rather than
    /// clamping on overflow (see `JSONValueConvertible`).
    public static func u64(_ value: UInt64) throws -> JSONValue {
        guard let int = Int64(exactly: value) else {
            throw JSONValueDecodingError.integerOutOfRange(field: "u64")
        }
        return .int(int)
    }

    // MARK: - Field access helpers (used by JSONValueConvertible models)

    /// Returns the field value, or nil when absent or explicit null.
    public func optionalField(_ name: String) -> JSONValue? {
        guard case .object(let object) = self, let value = object[name], value != .null else {
            return nil
        }
        return value
    }

    public func requiredField(_ name: String) throws -> JSONValue {
        guard let value = optionalField(name) else {
            throw JSONValueDecodingError.missingField(name)
        }
        return value
    }

    public func stringField(_ name: String) throws -> String {
        let value = try requiredField(name)
        guard let string = value.stringValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "string")
        }
        return string
    }

    public func optionalStringField(_ name: String) throws -> String? {
        guard let value = optionalField(name) else { return nil }
        guard let string = value.stringValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "string")
        }
        return string
    }

    public func intField(_ name: String) throws -> Int64 {
        let value = try requiredField(name)
        guard let int = value.intValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "integer")
        }
        return int
    }

    public func optionalIntField(_ name: String) throws -> Int64? {
        guard let value = optionalField(name) else { return nil }
        guard let int = value.intValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "integer")
        }
        return int
    }

    /// Unsigned 64-bit field; negative wire values are rejected.
    public func u64Field(_ name: String) throws -> UInt64 {
        let int = try intField(name)
        guard int >= 0 else {
            throw JSONValueDecodingError.integerOutOfRange(field: name)
        }
        return UInt64(bitPattern: int)
    }

    public func optionalU64Field(_ name: String) throws -> UInt64? {
        guard let int = try optionalIntField(name) else { return nil }
        guard int >= 0 else {
            throw JSONValueDecodingError.integerOutOfRange(field: name)
        }
        return UInt64(bitPattern: int)
    }

    public func boolField(_ name: String) throws -> Bool {
        let value = try requiredField(name)
        guard let bool = value.boolValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "boolean")
        }
        return bool
    }

    public func arrayField(_ name: String) throws -> [JSONValue] {
        let value = try requiredField(name)
        guard let array = value.arrayValue else {
            throw JSONValueDecodingError.wrongType(field: name, expected: "array")
        }
        return array
    }

    public func stringArrayField(_ name: String) throws -> [String] {
        try arrayField(name).map { element in
            guard let string = element.stringValue else {
                throw JSONValueDecodingError.wrongType(field: name, expected: "array of strings")
            }
            return string
        }
    }

    public func optionalStringArrayField(_ name: String) throws -> [String]? {
        guard optionalField(name) != nil else { return nil }
        return try stringArrayField(name)
    }

    public func nestedField<T: JSONValueConvertible>(_ name: String, as type: T.Type) throws -> T {
        try T(jsonValue: requiredField(name))
    }

    public func optionalNestedField<T: JSONValueConvertible>(_ name: String, as type: T.Type) throws -> T? {
        guard let value = optionalField(name) else { return nil }
        return try T(jsonValue: value)
    }

    public func nestedArrayField<T: JSONValueConvertible>(_ name: String, as type: T.Type) throws -> [T] {
        try arrayField(name).map { try T(jsonValue: $0) }
    }
}

// MARK: - Identifier conformances

extension AgentIdentifier: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = AgentIdentifier(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "agentIdentifier", reason: "not a valid agent identifier")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(rawValue) }
}

extension SessionID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = SessionID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "sessionID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension DeviceID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = DeviceID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "deviceID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension ProjectID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = ProjectID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "projectID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension ApprovalRequestID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = ApprovalRequestID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "approvalRequestID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension ApprovalRuleID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = ApprovalRuleID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "approvalRuleID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension ApprovalAuditEntryID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = ApprovalAuditEntryID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "approvalAuditEntryID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension ToolCallID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = ToolCallID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "toolCallID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension EventID: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = EventID(raw) else {
            throw JSONValueDecodingError.invalidValue(field: "eventID", reason: "not a UUID")
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(wireString) }
}

extension EventCursor: JSONValueConvertible {
    private enum Field {
        static let sessionID = "sessionID"
        static let lastEventSequence = "lastEventSequence"
    }

    public init(jsonValue: JSONValue) throws {
        self.init(
            sessionID: try jsonValue.nestedField(Field.sessionID, as: SessionID.self),
            lastEventSequence: try jsonValue.u64Field(Field.lastEventSequence)
        )
    }

    public func toJSONValue() throws -> JSONValue {
        .object([
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.lastEventSequence, try JSONValue.u64(lastEventSequence))
        ])
    }
}
