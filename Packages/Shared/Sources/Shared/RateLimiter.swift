//
//  RateLimiter.swift
//  Shared — AgentDeck
//
//  §13.4 rate limiting. Two shapes:
//   - `RateLimiter`: fixed-window attempt counters per key (connection
//     attempts). Fail-closed: at the limit, new attempts are denied (they
//     can only retry after the window slides).
//   - `FailureRateLimiter`: §13.4 pairing throttling — 5 FAILED attempts
//     per 10 minutes per source, plus an exponential backoff gate after
//     every failure. Successes and a Mac-side reset clear the state.
//  Both bound their key maps (stale entries evicted first; a full map of
//  live entries fails CLOSED, never silently unbounded). Actors per §25.
//

import Foundation

public actor RateLimiter {
    private struct Window: Sendable {
        var start: Int64
        var count: Int
    }

    private var windows: [String: Window] = [:]
    private let limit: Int
    private let windowMilliseconds: Int64
    private let maximumTrackedKeys: Int

    public init(limit: Int, windowMilliseconds: Int64, maximumTrackedKeys: Int = 1024) {
        self.limit = limit
        self.windowMilliseconds = windowMilliseconds
        self.maximumTrackedKeys = max(1, maximumTrackedKeys)
    }

    /// Records an attempt; returns false when `key` is at the limit for
    /// the current window (attempt denied).
    public func allow(_ key: String, now: Int64 = Date.unixMillisecondsNow) -> Bool {
        if var window = windows[key], now - window.start < windowMilliseconds {
            guard window.count < limit else {
                return false
            }
            window.count += 1
            windows[key] = window
            return true
        }
        guard makeRoomForNewKey(now: now) else {
            // Fail CLOSED: the map is full of live windows — denying an
            // untracked key is safer than unbounded growth (§20).
            return false
        }
        windows[key] = Window(start: now, count: 1)
        return true
    }

    /// Whether an attempt would be allowed WITHOUT recording it (UI hints).
    public func wouldAllow(_ key: String, now: Int64 = Date.unixMillisecondsNow) -> Bool {
        guard let window = windows[key], now - window.start < windowMilliseconds else {
            return true
        }
        return window.count < limit
    }

    public func reset(_ key: String) {
        windows[key] = nil
    }

    public func resetAll() {
        windows.removeAll()
    }

    /// Evicts expired windows so a new key fits; returns false when every
    /// tracked window is still live and the map is full.
    private func makeRoomForNewKey(now: Int64) -> Bool {
        guard windows.count >= maximumTrackedKeys else { return true }
        let staleKeys = windows.filter { now - $0.value.start >= windowMilliseconds }.map(\.key)
        for key in staleKeys {
            windows[key] = nil
        }
        return windows.count < maximumTrackedKeys
    }
}

/// §13.4 pairing throttle: counts FAILED attempts only, per source key
/// (connection endpoint — never a self-asserted device ID). After
/// `limit` failures inside the sliding window the source is denied until
/// the window slides; every failure also arms an exponential backoff gate
/// (base × 2ⁿ⁻¹, capped) so even sub-limit brute force slows down.
public actor FailureRateLimiter {
    private struct Record: Sendable {
        /// Failure timestamps still inside the sliding window.
        var failures: [Int64]
        /// Backoff gate: attempts before this instant are denied.
        var notBefore: Int64
    }

    private var records: [String: Record] = [:]
    private let limit: Int
    private let windowMilliseconds: Int64
    private let baseBackoffMilliseconds: Int64
    private let maximumBackoffMilliseconds: Int64
    private let maximumTrackedKeys: Int

    public init(
        limit: Int,
        windowMilliseconds: Int64,
        baseBackoffMilliseconds: Int64,
        maximumBackoffMilliseconds: Int64,
        maximumTrackedKeys: Int = 1024
    ) {
        self.limit = max(1, limit)
        self.windowMilliseconds = windowMilliseconds
        self.baseBackoffMilliseconds = max(0, baseBackoffMilliseconds)
        self.maximumBackoffMilliseconds = max(self.baseBackoffMilliseconds, maximumBackoffMilliseconds)
        self.maximumTrackedKeys = max(1, maximumTrackedKeys)
    }

    /// Whether an attempt may proceed right now. Records NOTHING — a
    /// denied check must never itself consume quota.
    public func wouldAllow(_ key: String, now: Int64 = Date.unixMillisecondsNow) -> Bool {
        guard var record = records[key] else { return true }
        prune(&record, now: now)
        if record.failures.isEmpty, now >= record.notBefore {
            records[key] = nil
            return true
        }
        records[key] = record
        guard now >= record.notBefore else { return false }
        return record.failures.count < limit
    }

    /// Records a FAILED attempt and returns the backoff delay (ms) now in
    /// effect for the source.
    @discardableResult
    public func recordFailure(_ key: String, now: Int64 = Date.unixMillisecondsNow) -> Int64 {
        var record = records[key] ?? Record(failures: [], notBefore: 0)
        prune(&record, now: now)
        record.failures.append(now)
        record.notBefore = now + backoff(forFailureCount: record.failures.count)
        records[key] = record
        evictIfNeeded(now: now)
        return record.notBefore - now
    }

    /// Clears the source's failure state after a fully successful pairing.
    public func recordSuccess(_ key: String) {
        records[key] = nil
    }

    /// Mac-side manual reset for the UI (§13.4 operator override).
    public func reset(_ key: String) {
        records[key] = nil
    }

    public func resetAll() {
        records.removeAll()
    }

    /// Exponential backoff: base × 2^(count−1), capped, overflow-safe.
    private func backoff(forFailureCount count: Int) -> Int64 {
        let shift = Swift.min(Swift.max(count - 1, 0), 20)
        let multiplier = Int64(1) << shift
        let (product, overflow) = baseBackoffMilliseconds.multipliedReportingOverflow(by: multiplier)
        if overflow || product > maximumBackoffMilliseconds {
            return maximumBackoffMilliseconds
        }
        return product
    }

    private func prune(_ record: inout Record, now: Int64) {
        record.failures.removeAll { now - $0 >= windowMilliseconds }
    }

    /// Bounds the map: fully-expired entries go first; when the map is
    /// still over capacity, the entries whose latest failure is OLDEST go
    /// next (LRU). The just-recorded key is newest, so a limiter flush can
    /// never erase the attempt being processed.
    private func evictIfNeeded(now: Int64) {
        guard records.count > maximumTrackedKeys else { return }
        for (key, record) in records where now - (record.failures.last ?? 0) >= windowMilliseconds && now >= record.notBefore {
            records[key] = nil
        }
        while records.count > maximumTrackedKeys,
              let oldest = records.min(by: { ($0.value.failures.last ?? 0) < ($1.value.failures.last ?? 0) })?.key {
            records[oldest] = nil
        }
    }
}
