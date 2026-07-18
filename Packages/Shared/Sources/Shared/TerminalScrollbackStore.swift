//
//  TerminalScrollbackStore.swift
//  Shared — AgentDeck
//
//  Bounded scrollback for terminal reattachment (§12.4, §29 Phase 5).
//

import Foundation

public enum TerminalScrollbackError: Error, Equatable {
    case capacityExceeded
}

/// Actor-backed scrollback buffer shared by companion PTY supervision and
/// iOS reattachment replay.
public actor TerminalScrollbackStore {
    public static let defaultCapacityBytes = 4 * 1_024 * 1_024

    private let capacityBytes: Int
    private var buffer = Data()

    public init(capacityBytes: Int = 4 * 1_024 * 1_024) {
        self.capacityBytes = max(1_024, capacityBytes)
    }

    public func append(_ chunk: Data) throws {
        guard !chunk.isEmpty else { return }
        if buffer.count + chunk.count <= capacityBytes {
            buffer.append(chunk)
            return
        }
        let overflow = buffer.count + chunk.count - capacityBytes
        if overflow >= buffer.count {
            buffer = chunk.suffix(capacityBytes)
        } else {
            buffer.removeFirst(overflow)
            buffer.append(chunk)
        }
    }

    public func snapshot() -> Data {
        buffer
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    public var byteCount: Int { buffer.count }
}
