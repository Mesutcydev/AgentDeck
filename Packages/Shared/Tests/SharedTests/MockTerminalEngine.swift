//
//  MockTerminalEngine.swift
//  SharedTests — AgentDeck
//
//  In-memory TerminalEngine test double. Lives in the test target — the
//  library target ships no mock scaffolding.
//

import Foundation
@testable import Shared

/// In-memory test engine — records feeds and obeys read-only mode.
final class MockTerminalEngine: TerminalEngine, @unchecked Sendable {
    var interactionMode: TerminalInteractionMode = .interactive
    private(set) var size: TerminalSize
    private(set) var fed: [Data] = []
    private(set) var inputs: [Data] = []
    private(set) var scrollback = Data()

    init(size: TerminalSize = TerminalSize(cols: 80, rows: 24)) {
        self.size = size
    }

    func feed(_ data: Data) {
        fed.append(data)
        scrollback.append(data)
    }

    func sendInput(_ data: Data) {
        guard interactionMode == .interactive else { return }
        inputs.append(data)
    }

    func resize(to size: TerminalSize) {
        self.size = size
    }

    func scrollbackSnapshot() -> Data {
        scrollback
    }
}
