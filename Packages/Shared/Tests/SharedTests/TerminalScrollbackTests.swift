//
//  TerminalScrollbackTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("TerminalScrollbackStore")
struct TerminalScrollbackTests {
    @Test("bounded store truncates oldest bytes")
    func truncation() async throws {
        let store = TerminalScrollbackStore(capacityBytes: 1024)
        try await store.append(Data(repeating: 0x01, count: 800))
        try await store.append(Data(repeating: 0x02, count: 800))
        let count = await store.byteCount
        #expect(count == 1024)
    }
}
