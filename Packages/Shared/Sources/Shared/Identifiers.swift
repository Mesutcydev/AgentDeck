//
//  Identifiers.swift
//  Shared — AgentDeck
//
//  Core identifier types (SPEC §10.2). Strong wrappers prevent mixing up
//  id domains at compile time. Everything is value-typed and Sendable (§25).
//

import Foundation

/// Identifier for an agent integration (adapter), e.g. `com.example.adapter`.
/// Provider-agnostic: the shared package defines no concrete adapter ids.
public struct AgentIdentifier: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    /// Reverse-DNS style identifier; must be non-empty and contain no whitespace.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.allSatisfy({ !$0.isWhitespace }),
              rawValue.count <= 128 else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Base for UUID-backed identifier wrappers.
public protocol UUIDIdentified: Hashable, Sendable, CustomStringConvertible {
    var uuid: UUID { get }
    init(uuid: UUID)
}

extension UUIDIdentified {
    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(uuid: uuid)
    }

    /// Random identifier (v4 UUID). Device IDs are random per installation and
    /// never derived from hardware identifiers (SPEC §13.1).
    public static func random() -> Self { Self(uuid: UUID()) }

    /// Canonical lowercase string form used on the wire.
    public var wireString: String { uuid.uuidString.lowercased() }

    public var description: String { wireString }
}

public struct SessionID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct DeviceID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct ProjectID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct ApprovalRequestID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct ApprovalRuleID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct ApprovalAuditEntryID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct ToolCallID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct EventID: UUIDIdentified {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Resume position in a session's event stream (SPEC §9 `cursor`, §14.1).
/// Opaque to consumers; ordered by per-session event sequence.
public struct EventCursor: Hashable, Sendable {
    public let sessionID: SessionID
    /// Sequence number of the last event the peer has durably received.
    public let lastEventSequence: UInt64

    public init(sessionID: SessionID, lastEventSequence: UInt64) {
        self.sessionID = sessionID
        self.lastEventSequence = lastEventSequence
    }
}

extension EventCursor: Comparable {
    public static func < (lhs: EventCursor, rhs: EventCursor) -> Bool {
        lhs.lastEventSequence < rhs.lastEventSequence
    }
}
