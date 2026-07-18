//
//  TerminalFramesTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("§9 terminal stream frames")
struct TerminalFramesTests {
    @Test("terminal output payload round-trips")
    func outputRoundTrip() throws {
        let sessionID = SessionID.random()
        let payload = TerminalOutputPayload(
            sessionID: sessionID,
            data: Data("hello\r\n".utf8),
            isReplay: true
        )
        let decoded = try TerminalOutputPayload(jsonValue: payload.toJSONValue())
        #expect(decoded == payload)
    }

    @Test("terminal input payload round-trips")
    func inputRoundTrip() throws {
        let sessionID = SessionID.random()
        let payload = TerminalInputPayload(sessionID: sessionID, data: Data([0x03]))
        let decoded = try TerminalInputPayload(jsonValue: payload.toJSONValue())
        #expect(decoded == payload)
    }
}
