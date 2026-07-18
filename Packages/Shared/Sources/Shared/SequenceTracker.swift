//
//  SequenceTracker.swift
//  Shared — AgentDeck
//
//  §9 seq/ack bookkeeping. seq is per-direction, monotonic from 1. ack is
//  the highest CONTIGUOUS seq received from the peer. Value type: the
//  transport (Phase 3) owns one tracker per connection inside its actor.
//

import Foundation

/// What happened when an incoming seq was recorded.
public enum SequenceReception: Sendable, Equatable {
    /// Frame filled the next expected position; ack advanced (possibly
    /// draining buffered out-of-order frames). Carries the new ack value.
    case advanced(newAck: UInt64)
    /// Frame arrived ahead of a gap; buffered until the gap fills.
    case buffered(pendingGap: UInt64)
    /// seq was already accounted for (retransmit); state unchanged.
    case duplicate
}

/// Tracks outgoing seq and incoming contiguous-ack state for one direction
/// pair of a connection (§9).
public struct SequenceTracker: Sendable {
    /// Bounds memory when a peer sends far-future seqs (a 4 GiB gap must
    /// not allocate 4 GiB of bookkeeping).
    public static let defaultMaximumBuffered = 1024

    private var nextOutgoing: UInt64 = 1
    private var highestContiguousIncoming: UInt64 = 0
    private var bufferedIncoming: Set<UInt64> = []
    private let maximumBuffered: Int

    public init(maximumBuffered: Int = SequenceTracker.defaultMaximumBuffered) {
        self.maximumBuffered = maximumBuffered
    }

    // MARK: - Outgoing

    /// The seq to stamp on the next outgoing frame. Starts at 1 (§9) and
    /// never decreases for the life of the tracker.
    public var nextOutgoingSequence: UInt64 { nextOutgoing }

    /// Consumes the next outgoing seq (call once per frame sent).
    public mutating func consumeOutgoingSequence() -> UInt64 {
        let seq = nextOutgoing
        nextOutgoing += 1
        return seq
    }

    // MARK: - Incoming

    /// Highest contiguous seq received from the peer — the value stamped
    /// into outgoing `ack` fields (§9).
    public var currentAck: UInt64 { highestContiguousIncoming }

    /// Records an incoming frame's seq.
    /// - Throws: `FrameError.invalidSequence` for seq 0 (§9: monotonic
    ///   from 1) or when the out-of-order buffer is full (peer misbehavior).
    public mutating func recordIncoming(_ seq: UInt64) throws -> SequenceReception {
        guard seq >= 1 else {
            throw FrameError.invalidSequence(seq)
        }
        if seq <= highestContiguousIncoming || bufferedIncoming.contains(seq) {
            return .duplicate
        }
        if seq == highestContiguousIncoming + 1 {
            highestContiguousIncoming = seq
            // Drain any buffered run directly above the new position.
            while bufferedIncoming.contains(highestContiguousIncoming + 1) {
                highestContiguousIncoming += 1
                bufferedIncoming.remove(highestContiguousIncoming)
            }
            return .advanced(newAck: highestContiguousIncoming)
        }
        guard bufferedIncoming.count < maximumBuffered else {
            throw FrameError.invalidSequence(seq)
        }
        bufferedIncoming.insert(seq)
        return .buffered(pendingGap: highestContiguousIncoming + 1)
    }
}
