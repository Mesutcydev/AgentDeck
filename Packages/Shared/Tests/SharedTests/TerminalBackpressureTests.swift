//
//  TerminalBackpressureTests.swift
//  SharedTests — AgentDeck
//

import Testing
@testable import Shared

@Suite("§23 terminal backpressure")
struct TerminalBackpressureTests {
    @Test("accepts output under 1 MB/s")
    func underLimit() {
        var gate = TerminalBackpressureGate(limitBytesPerSecond: 1_000_000, now: 0)
        #expect(gate.evaluate(count: 500_000, now: 0) == .accept)
        #expect(gate.evaluate(count: 400_000, now: 500) == .accept)
    }

    @Test("drops bytes beyond 1 MB/s in the same window")
    func overLimit() {
        var gate = TerminalBackpressureGate(limitBytesPerSecond: 1_000_000, now: 0)
        #expect(gate.evaluate(count: 900_000, now: 0) == .accept)
        #expect(gate.evaluate(count: 200_000, now: 100) == .drop(count: 100_000))
    }

    @Test("window resets after one second")
    func windowReset() {
        var gate = TerminalBackpressureGate(limitBytesPerSecond: 100, now: 0)
        #expect(gate.evaluate(count: 100, now: 0) == .accept)
        #expect(gate.evaluate(count: 50, now: 500) == .drop(count: 50))
        #expect(gate.evaluate(count: 50, now: 1_100) == .accept)
    }
}
