//
//  RateLimiterTests.swift
//  SharedTests — AgentDeck
//
//  §13.4 rate limiting: fixed-window attempt counters and the pairing
//  failure throttle (5 FAILED attempts / 10 min / source + exponential
//  backoff + Mac-side reset), including bounded-map behavior.
//

import Foundation
import Testing
@testable import Shared

@Suite("§13.4 fixed-window rate limiter")
struct RateLimiterTests {
    @Test("attempts up to the limit pass; the next is denied until the window slides")
    func windowSemantics() async {
        let limiter = RateLimiter(limit: 3, windowMilliseconds: 60_000)
        #expect(await limiter.allow("source", now: 1_000))
        #expect(await limiter.allow("source", now: 2_000))
        #expect(await limiter.allow("source", now: 3_000))
        #expect(await limiter.allow("source", now: 4_000) == false, "4th attempt in the window is denied")
        // Denials do not consume quota: still denied on re-check.
        #expect(await limiter.wouldAllow("source", now: 5_000) == false)
        // Window slides: the first attempt ages out.
        #expect(await limiter.allow("source", now: 61_001))
    }

    @Test("wouldAllow never records an attempt")
    func wouldAllowIsReadOnly() async {
        let limiter = RateLimiter(limit: 1, windowMilliseconds: 60_000)
        #expect(await limiter.wouldAllow("k", now: 0))
        #expect(await limiter.wouldAllow("k", now: 0))
        #expect(await limiter.allow("k", now: 0), "peeked quota is still available")
        #expect(await limiter.wouldAllow("k", now: 0) == false)
    }

    @Test("reset clears one key; resetAll clears everything")
    func reset() async {
        let limiter = RateLimiter(limit: 1, windowMilliseconds: 60_000)
        #expect(await limiter.allow("a", now: 0))
        #expect(await limiter.allow("b", now: 0))
        await limiter.reset("a")
        #expect(await limiter.allow("a", now: 0), "reset key may retry")
        #expect(await limiter.allow("b", now: 0) == false, "other keys are untouched")
        await limiter.resetAll()
        #expect(await limiter.allow("b", now: 0))
    }

    @Test("the windows map is bounded: full-of-live windows fails closed, stale entries evict")
    func boundedMap() async {
        let limiter = RateLimiter(limit: 1, windowMilliseconds: 60_000, maximumTrackedKeys: 2)
        #expect(await limiter.allow("a", now: 0))
        #expect(await limiter.allow("b", now: 0))
        #expect(await limiter.allow("c", now: 0) == false, "a third live key is denied, not tracked")
        // After the windows slide, stale entries evict and new keys fit.
        #expect(await limiter.allow("c", now: 61_000), "expired windows make room")
    }
}

@Suite("§13.4 pairing failure throttle")
struct FailureRateLimiterTests {
    private func makeLimiter(
        limit: Int = 5,
        base: Int64 = 1_000,
        maxBackoff: Int64 = 300_000
    ) -> FailureRateLimiter {
        FailureRateLimiter(
            limit: limit,
            windowMilliseconds: 600_000,
            baseBackoffMilliseconds: base,
            maximumBackoffMilliseconds: maxBackoff
        )
    }

    @Test("only FAILED attempts count: checks and successes never consume quota")
    func failuresOnly() async {
        let limiter = makeLimiter(limit: 2, base: 0)
        #expect(await limiter.wouldAllow("src", now: 0))
        #expect(await limiter.wouldAllow("src", now: 0))
        await limiter.recordSuccess("src")
        #expect(await limiter.wouldAllow("src", now: 0), "no failures recorded, still allowed")
    }

    @Test("five failures inside ten minutes deny the source until the window slides")
    func fivePerTenMinutes() async {
        let limiter = makeLimiter(limit: 5, base: 0)
        for index in 0..<5 {
            #expect(await limiter.wouldAllow("src", now: Int64(index) * 1_000))
            await limiter.recordFailure("src", now: Int64(index) * 1_000)
        }
        #expect(await limiter.wouldAllow("src", now: 5_000) == false, "6th attempt is denied")
        // Ten minutes after the FIRST failure, the window has slid.
        #expect(await limiter.wouldAllow("src", now: 600_000), "window slide frees the source")
    }

    @Test("failures are independent per source key")
    func perSource() async {
        let limiter = makeLimiter(limit: 1, base: 0)
        await limiter.recordFailure("a", now: 0)
        #expect(await limiter.wouldAllow("a", now: 1) == false)
        #expect(await limiter.wouldAllow("b", now: 1), "other sources are unaffected")
    }

    @Test("backoff grows exponentially and is capped")
    func exponentialBackoff() async {
        let limiter = makeLimiter(limit: 100, base: 1_000, maxBackoff: 10_000)
        #expect(await limiter.recordFailure("src", now: 0) == 1_000)
        #expect(await limiter.recordFailure("src", now: 1_000) == 2_000)
        #expect(await limiter.recordFailure("src", now: 2_000) == 4_000)
        #expect(await limiter.recordFailure("src", now: 3_000) == 8_000)
        #expect(await limiter.recordFailure("src", now: 4_000) == 10_000, "capped at the maximum")
        #expect(await limiter.recordFailure("src", now: 5_000) == 10_000)
    }

    @Test("the backoff gate denies attempts even below the failure limit")
    func backoffGate() async {
        let limiter = makeLimiter(limit: 5, base: 10_000)
        await limiter.recordFailure("src", now: 0)
        #expect(await limiter.wouldAllow("src", now: 5_000) == false, "inside the backoff gate")
        #expect(await limiter.wouldAllow("src", now: 10_000), "gate lifts after the backoff")
    }

    @Test("success clears failure state; the Mac-side reset path does too")
    func successAndReset() async {
        let limiter = makeLimiter(limit: 1, base: 10_000)
        await limiter.recordFailure("src", now: 0)
        #expect(await limiter.wouldAllow("src", now: 0) == false)
        await limiter.recordSuccess("src")
        #expect(await limiter.wouldAllow("src", now: 0), "a full success clears the slate")

        await limiter.recordFailure("src", now: 0)
        #expect(await limiter.wouldAllow("src", now: 0) == false)
        await limiter.reset("src")
        #expect(await limiter.wouldAllow("src", now: 0), "operator reset lets the user retry")

        await limiter.recordFailure("src", now: 0)
        await limiter.resetAll()
        #expect(await limiter.wouldAllow("src", now: 0))
    }

    @Test("the records map is strictly bounded, evicting the oldest failure history")
    func boundedMap() async {
        let limiter = FailureRateLimiter(
            limit: 10,
            windowMilliseconds: 600_000,
            baseBackoffMilliseconds: 0,
            maximumBackoffMilliseconds: 0,
            maximumTrackedKeys: 2
        )
        await limiter.recordFailure("a", now: 0)
        await limiter.recordFailure("b", now: 1)
        await limiter.recordFailure("c", now: 2)
        // 'a' (oldest) was evicted to make room for 'c'.
        #expect(await limiter.wouldAllow("a", now: 3), "evicted source has no history")
        #expect(await limiter.recordFailure("a", now: 3) == 0, "re-tracking works after eviction")
    }
}
