//
//  TerminalBackpressure.swift
//  Shared — AgentDeck
//
//  §23 terminal budget: backpressure engages beyond 1 MB/s sustained output.
//

import Foundation

public enum TerminalBackpressureAction: Sendable, Equatable {
    case accept
    case drop(count: Int)
}

/// Sliding-window byte rate limiter for terminal output streams.
public struct TerminalBackpressureGate: Sendable {
    /// §23: 1 MB/s sustained output triggers backpressure.
    public static let defaultBytesPerSecond = 1_000_000

    private let limitBytesPerSecond: Int
    private var windowStart: Int64
    private var windowBytes: Int

    public init(limitBytesPerSecond: Int = Self.defaultBytesPerSecond, now: Int64 = 0) {
        self.limitBytesPerSecond = limitBytesPerSecond
        self.windowStart = now
        self.windowBytes = 0
    }

    /// Returns whether `count` bytes may be accepted in the current 1 s window.
    public mutating func evaluate(count: Int, now: Int64) -> TerminalBackpressureAction {
        guard count > 0 else { return .accept }
        if now - windowStart >= 1_000 {
            windowStart = now
            windowBytes = 0
        }
        let remaining = max(0, limitBytesPerSecond - windowBytes)
        if count <= remaining {
            windowBytes += count
            return .accept
        }
        let accepted = remaining
        windowBytes += accepted
        return .drop(count: count - accepted)
    }

    public var isUnderPressure: Bool {
        windowBytes >= limitBytesPerSecond
    }
}
