//
//  TerminalIntegrationTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("§29 terminal stream")
struct TerminalIntegrationTests {
    @Test("scrollback replay emits chunked terminal.output payloads")
    func replayChunks() throws {
        let sessionID = SessionID.random()
        let data = Data(repeating: 0x41, count: 9000)
        let payloads = TerminalStreamBridge.replayChunks(sessionID: sessionID, scrollback: data, chunkSize: 4096)
        #expect(payloads.count == 3)
        let first = try TerminalStreamBridge.parseOutput(payloads[0])
        #expect(first.isReplay)
        #expect(first.sessionID == sessionID)
    }
}
