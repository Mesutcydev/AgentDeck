//
//  BoundedLineBuffer.swift
//  Shared — AgentDeck
//
//  Bounded newline-delimited accumulator for agent stdout/stderr. A hostile
//  or hung agent can emit unlimited bytes without a newline; every consumer
//  (JSON-RPC stdio clients, Claude stream-json pipes) caps retained bytes
//  here instead of growing without bound.
//

import Foundation

public struct BoundedLineBuffer: Sendable, Equatable {
    /// Maximum bytes kept for a single line before truncation (1 MiB).
    public static let defaultMaxLineBytes = 1_024 * 1_024
    /// Maximum retained buffer bytes (4 MiB), matching the terminal
    /// scrollback budget (`TerminalScrollbackStore.defaultCapacityBytes`).
    public static let defaultMaxBufferBytes = 4 * 1_024 * 1_024
    /// Marker appended to truncated lines / emitted when bytes are dropped.
    public static let truncationMarker = "[AgentDeck truncated over-limit output]"

    private let maxLineBytes: Int
    private let maxBufferBytes: Int
    private var buffer = Data()

    public init(
        maxLineBytes: Int = BoundedLineBuffer.defaultMaxLineBytes,
        maxBufferBytes: Int = BoundedLineBuffer.defaultMaxBufferBytes
    ) {
        self.maxLineBytes = max(1_024, maxLineBytes)
        self.maxBufferBytes = max(1_024, maxBufferBytes)
    }

    public var pendingByteCount: Int { buffer.count }

    /// Appends a chunk and returns every completed line (newline stripped,
    /// not trimmed). Over-long lines are truncated to `maxLineBytes` with
    /// `truncationMarker` appended; when the retained buffer would exceed
    /// `maxBufferBytes` the oldest bytes are dropped (newest kept, matching
    /// terminal scrollback policy) and a marker line is emitted first.
    public mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            // subdata rebases indices to zero — Data slices after removal
            // are not guaranteed zero-based, and raw 0-based ranges trap.
            buffer = buffer.subdata(in: buffer.index(after: newlineIndex)..<buffer.endIndex)
            if lineData.count > maxLineBytes {
                lines.append(String(decoding: lineData.prefix(maxLineBytes), as: UTF8.self) + Self.truncationMarker)
            } else {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        if buffer.count > maxBufferBytes {
            buffer = buffer.subdata(in: buffer.index(buffer.endIndex, offsetBy: -maxBufferBytes)..<buffer.endIndex)
            lines.insert(Self.truncationMarker, at: 0)
        }
        return lines
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
