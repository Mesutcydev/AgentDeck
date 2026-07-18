//
//  TerminalEngineTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("TerminalEngine protocol")
struct TerminalEngineTests {
    @Test("mock engine records feeds and honors read-only mode")
    func mockEngine() {
        let engine = MockTerminalEngine()
        engine.feed(Data("output".utf8))
        engine.interactionMode = .readOnlyRawOutput
        engine.sendInput(Data([0x1b]))
        #expect(engine.fed.count == 1)
        #expect(engine.inputs.isEmpty)
        #expect(engine.scrollbackSnapshot() == Data("output".utf8))
    }
}
