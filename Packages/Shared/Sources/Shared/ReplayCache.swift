//
//  ReplayCache.swift
//  Shared — AgentDeck
//
//  Replay protection for §9: every frame carries a random 16-byte nonce;
//  a nonce seen before means the frame is a replay (or a collision the
//  sender must not produce). Actor per SPEC §25 (actors for mutable
//  shared state).
//

import Foundation

/// Nonce replay cache for the §9 wire protocol.
///
/// Policy: `checkAndInsert` returns false for a nonce already present
/// (replay — caller drops the frame). Expired entries are purged lazily on
/// insert. At capacity, NEW nonces are rejected (fail-safe: evicting live
/// entries would reopen a replay window; denying fresh frames only costs a
/// resend).
public actor ReplayCache {
    /// Default retention: 10 minutes — far beyond the ±30 s timestamp
    /// acceptance window, so a replayed frame always still has its nonce
    /// cached when it could pass timestamp validation.
    public static let defaultLifetimeMilliseconds: Int64 = 600_000

    /// Default capacity: 100k entries ≈ 6.4 MB worst case (16-byte nonce +
    /// 8-byte timestamp + dictionary overhead per entry).
    public static let defaultMaximumEntries = 100_000

    private var entries: [Data: Int64] = [:] // nonce → first-seen unix ms
    private let lifetime: Int64
    private let maximumEntries: Int

    public init(
        entryLifetimeMilliseconds: Int64 = ReplayCache.defaultLifetimeMilliseconds,
        maximumEntries: Int = ReplayCache.defaultMaximumEntries
    ) {
        self.lifetime = entryLifetimeMilliseconds
        self.maximumEntries = maximumEntries
    }

    /// Returns true when the nonce is new and is now recorded; false when
    /// it was already seen (replay) or the cache is full.
    public func checkAndInsert(_ nonce: Data, now: Int64 = Date.unixMillisecondsNow) -> Bool {
        purgeExpired(now: now)
        if entries[nonce] != nil {
            return false
        }
        guard entries.count < maximumEntries else {
            return false
        }
        entries[nonce] = now
        return true
    }

    /// Number of live entries (test/diagnostic visibility).
    public var count: Int { entries.count }

    private func purgeExpired(now: Int64) {
        let cutoff = now - lifetime
        entries = entries.filter { $0.value >= cutoff }
    }
}
