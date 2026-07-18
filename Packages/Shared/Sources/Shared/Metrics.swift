//
//  Metrics.swift
//  Shared — AgentDeck
//
//  §23 measurement scaffolding: os_signpost wrappers plus simple counters
//  the transport (Phase 3) and profiling passes (Phase 12) consume, so
//  budgets are checkable as the code lands. Instances are created and
//  injected by their owner — no global mutable singletons (§25).
//

import Foundation
import OSLog

/// Signpost instrumentation around §23-budgeted operations.
/// Created by the owner of the measured subsystem (e.g. the transport).
public struct DeckSignposter: Sendable {
    private let signposter: OSSignposter

    /// - Parameter category: signpost category; use `.pointsOfInterest`
    ///   for §23 budget checks so they surface in Instruments.
    public init(category: String, pointsOfInterest: Bool = false) {
        self.signposter = OSSignposter(
            subsystem: ProductNaming.logSubsystem,
            category: pointsOfInterest ? OSLog.Category.pointsOfInterest.rawValue : category
        )
    }

    /// Begins an interval measurement (e.g. "qr-to-paired", "frame-roundtrip").
    public func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Emits a moment-in-time event (e.g. "frame-sent").
    public func emitEvent(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// Measures a synchronous operation end-to-end.
    public func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try operation()
    }

    /// Measures an asynchronous operation end-to-end.
    public func measure<T>(_ name: StaticString, _ operation: () async throws -> T) async rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try await operation()
    }
}

/// Standard counter names. Defined once here so transport, companion, and
/// tests count the same things (§23); extend as later phases need more.
public enum MetricName: String, Sendable, CaseIterable {
    case framesSent
    case framesReceived
    case frameBytesSent
    case frameBytesReceived
    case framesRejectedSignature
    case framesRejectedReplay
    case framesRejectedTimestamp
    case framesRejectedOversize
    case replayCacheInsertions
    case outOfOrderFramesBuffered
}

/// A tiny named-counter store. Actor-isolated (§25); owned and injected by
/// the subsystem that counts (the transport in Phase 3). Values are
/// read back in tests and diagnostics exports.
public actor MetricsCounter {
    private var counters: [MetricName: Int64] = [:]

    public init() {}

    public func increment(_ name: MetricName, by amount: Int64 = 1) {
        counters[name, default: 0] += amount
    }

    public func value(of name: MetricName) -> Int64 {
        counters[name, default: 0]
    }

    public func snapshot() -> [MetricName: Int64] {
        counters
    }

    public func reset() {
        counters.removeAll()
    }
}
