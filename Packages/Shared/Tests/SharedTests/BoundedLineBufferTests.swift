//
//  BoundedLineBufferTests.swift
//  SharedTests — AgentDeck
//
//  Buffer-budget coverage: over-long lines truncate with a marker and the
//  retained buffer never exceeds the 4 MiB terminal-style budget.
//

import Foundation
import Testing
@testable import Shared

@Suite("bounded line buffer")
struct BoundedLineBufferTests {
    @Test("complete lines are returned, partial tail is retained")
    func lineSplitting() {
        var buffer = BoundedLineBuffer()
        #expect(buffer.append(Data("one\ntwo".utf8)) == ["one"])
        #expect(buffer.append(Data("\nthree\n".utf8)) == ["two", "three"])
        #expect(buffer.pendingByteCount == 0)
    }

    @Test("over-long line is truncated to 1 MiB with marker")
    func lineTruncation() {
        var buffer = BoundedLineBuffer()
        let oversized = String(repeating: "x", count: BoundedLineBuffer.defaultMaxLineBytes + 500)
        let lines = buffer.append(Data((oversized + "\n").utf8))
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.hasSuffix(BoundedLineBuffer.truncationMarker))
        #expect(line.utf8.count == BoundedLineBuffer.defaultMaxLineBytes + BoundedLineBuffer.truncationMarker.utf8.count)
    }

    @Test("retained buffer never exceeds budget; oldest bytes drop with marker")
    func bufferTruncation() {
        var buffer = BoundedLineBuffer(maxLineBytes: 1_024, maxBufferBytes: 4_096)
        // 3 KiB without a newline, then another 3 KiB: total 6 KiB > 4 KiB cap.
        let first = buffer.append(Data(repeating: 0x61, count: 3_072))
        #expect(first.isEmpty)
        let second = buffer.append(Data(repeating: 0x62, count: 3_072))
        #expect(second == [BoundedLineBuffer.truncationMarker])
        #expect(buffer.pendingByteCount <= 4_096)

        // A newline afterwards yields a line built only from retained bytes.
        let tail = buffer.append(Data("\n".utf8))
        #expect(tail.count == 1)
        #expect(tail[0].utf8.count <= 1_024 + BoundedLineBuffer.truncationMarker.utf8.count)
    }

    @Test("custom budgets are honored")
    func customBudgets() {
        var buffer = BoundedLineBuffer(maxLineBytes: 1_024, maxBufferBytes: 2_048)
        _ = buffer.append(Data(repeating: 0x63, count: 4_096))
        #expect(buffer.pendingByteCount <= 2_048)
    }
}
