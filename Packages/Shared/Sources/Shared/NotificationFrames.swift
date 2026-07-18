//
//  NotificationFrames.swift
//  Shared — AgentDeck
//
//  §29 Phase 10 device push registration and notification deep-link payloads.
//

import Foundation

/// iOS device registers its opaque push destination token with the companion.
public struct DevicePushTokenRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let deviceID: DeviceID
    public let destinationToken: PushDestinationToken

    public init(deviceID: DeviceID, destinationToken: PushDestinationToken) {
        self.deviceID = deviceID
        self.destinationToken = destinationToken
    }
}

extension DevicePushTokenRequest: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let deviceID = "deviceID"
        static let destinationToken = "destinationToken"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.deviceID = try jsonValue.nestedField(Field.deviceID, as: DeviceID.self)
        guard let token = PushDestinationToken(try jsonValue.stringField(Field.destinationToken)) else {
            throw JSONValueDecodingError.invalidValue(field: Field.destinationToken, reason: "invalid token")
        }
        self.destinationToken = token
    }

    public func toJSONValue() throws -> JSONValue {
        .object([
            (Field.payloadV, .int(Self.payloadV)),
            (Field.deviceID, deviceID.toJSONValue()),
            (Field.destinationToken, .string(destinationToken.rawValue))
        ])
    }
}

/// Deep-link metadata delivered inside a push notification userInfo blob.
public struct NotificationDeepLink: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let sessionID: SessionID
    public let eventType: RelayNotificationEventType
    public let cursor: EventCursor?

    public init(sessionID: SessionID, eventType: RelayNotificationEventType, cursor: EventCursor?) {
        self.sessionID = sessionID
        self.eventType = eventType
        self.cursor = cursor
    }
}

extension NotificationDeepLink: JSONValueConvertible {
    private enum Field {
        static let payloadV = "payloadV"
        static let sessionID = "sessionID"
        static let eventType = "eventType"
        static let cursor = "cursor"
    }

    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Field.payloadV)
        guard version == Self.payloadV else {
            throw JSONValueDecodingError.unsupportedPayloadVersion(found: version, supported: Self.payloadV)
        }
        self.sessionID = try jsonValue.nestedField(Field.sessionID, as: SessionID.self)
        self.eventType = try jsonValue.nestedField(Field.eventType, as: RelayNotificationEventType.self)
        self.cursor = try jsonValue.optionalNestedField(Field.cursor, as: EventCursor.self)
    }

    public func toJSONValue() throws -> JSONValue {
        var entries: [(String, JSONValue)] = [
            (Field.payloadV, .int(Self.payloadV)),
            (Field.sessionID, sessionID.toJSONValue()),
            (Field.eventType, eventType.toJSONValue())
        ]
        if let cursor {
            entries.append((Field.cursor, try cursor.toJSONValue()))
        }
        return .object(entries)
    }
}

extension NotificationDeepLink {
    public func userInfoDictionary() -> [String: String] {
        var info: [String: String] = [
            "sessionID": sessionID.wireString,
            "eventType": eventType.rawValue
        ]
        if let cursor {
            info["lastEventSequence"] = String(cursor.lastEventSequence)
        }
        return info
    }

    public static func parse(userInfo: [AnyHashable: Any]) -> NotificationDeepLink? {
        guard
            let sessionText = userInfo["sessionID"] as? String,
            let sessionID = SessionID(sessionText),
            let eventText = userInfo["eventType"] as? String,
            let eventType = RelayNotificationEventType(rawValue: eventText)
        else {
            return nil
        }
        let cursor: EventCursor?
        if let sequenceText = userInfo["lastEventSequence"] as? String,
           let sequence = UInt64(sequenceText) {
            cursor = EventCursor(sessionID: sessionID, lastEventSequence: sequence)
        } else {
            cursor = nil
        }
        return NotificationDeepLink(sessionID: sessionID, eventType: eventType, cursor: cursor)
    }
}
