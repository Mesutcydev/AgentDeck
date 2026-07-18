//
//  EventConfidence.swift
//  Shared — AgentDeck
//
//  §10.4 adapter confidence model (normative):
//    1.0 native structured protocol event (app-server, ACP, hooks)
//    0.7 versioned stream output parsed with schema match
//    0.4 PTY heuristic parse
//    0.0 unknown / unparsed
//  Events below 0.7 render with a visible "uncertain" indicator and are
//  NEVER approval-eligible. That rule is encoded as API here — approval
//  payloads require the `ApprovalEligibleConfidence` wrapper, which
//  cannot be constructed below 0.7 — not as convention.
//
//  Wire encoding: integer basis points (10000 = 1.0 … 0 = 0.0), because
//  v1 frames carry no floats (SPEC §9). See ADR-0006.
//

import Foundation

public enum EventConfidence: String, Sendable, CaseIterable, Codable {
    /// 1.0 — native structured protocol event (app-server, ACP, hooks).
    case native
    /// 0.7 — versioned stream output parsed with schema match.
    case versionedStream
    /// 0.4 — PTY heuristic parse.
    case ptyHeuristic
    /// 0.0 — unknown / unparsed.
    case unknown

    /// §10.4 value encoded as integer basis points (wire form).
    public var basisPoints: Int64 {
        switch self {
        case .native: 10_000
        case .versionedStream: 7_000
        case .ptyHeuristic: 4_000
        case .unknown: 0
        }
    }

    public init?(basisPoints: Int64) {
        switch basisPoints {
        case 10_000: self = .native
        case 7_000: self = .versionedStream
        case 4_000: self = .ptyHeuristic
        case 0: self = .unknown
        default: return nil
        }
    }

    /// §10.4: events below 0.7 are never approval-eligible.
    public var isApprovalEligible: Bool {
        self == .native || self == .versionedStream
    }

    /// §10.4: events below 0.7 render with a visible "uncertain" indicator.
    public var requiresUncertaintyIndicator: Bool { !isApprovalEligible }
}

extension EventConfidence: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let int = jsonValue.intValue, let value = EventConfidence(basisPoints: int) else {
            throw JSONValueDecodingError.invalidValue(
                field: "confidence", reason: "not a §10.4 basis-point value (10000/7000/4000/0)"
            )
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .int(basisPoints) }
}

/// A confidence value proven ≥ 0.7 (§10.4). ApprovalRequest requires this
/// wrapper, so an approval card can never be populated from an uncertain
/// (PTY-heuristic or unknown) event — the type system enforces what
/// §10.4 demands.
public struct ApprovalEligibleConfidence: Sendable, Hashable {
    public let confidence: EventConfidence

    /// Returns nil for confidence below 0.7 — by design the only way to
    /// obtain this type is with an approval-eligible value.
    public init?(_ confidence: EventConfidence) {
        guard confidence.isApprovalEligible else { return nil }
        self.confidence = confidence
    }

    public var basisPoints: Int64 { confidence.basisPoints }
}

extension ApprovalEligibleConfidence: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        let confidence = try EventConfidence(jsonValue: jsonValue)
        guard let eligible = ApprovalEligibleConfidence(confidence) else {
            throw JSONValueDecodingError.invalidValue(
                field: "confidence", reason: "below 0.7 — not approval-eligible (§10.4)"
            )
        }
        self = eligible
    }

    public func toJSONValue() -> JSONValue { confidence.toJSONValue() }
}
