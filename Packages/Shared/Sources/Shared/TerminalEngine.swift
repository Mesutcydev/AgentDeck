//
//  TerminalEngine.swift
//  Shared — AgentDeck
//
//  §29 Phase 5: swappable terminal engine protocol. SwiftTerm (App target)
//  implements this; business logic never parses escape sequences (§25).
//

import Foundation

/// Interaction mode for a session terminal surface.
public enum TerminalInteractionMode: Sendable, Equatable {
    /// Full PTY/TUI input and rendering.
    case interactive
    /// §10.4 degraded path — output only, no keystrokes forwarded.
    case readOnlyRawOutput
}

/// Engine-facing terminal dimensions (character cells).
public struct TerminalSize: Sendable, Equatable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// Callbacks from a concrete terminal engine implementation (App target).
public struct TerminalEngineCallbacks: Sendable {
    public var onInput: @Sendable (Data) -> Void
    public var onResize: @Sendable (TerminalSize) -> Void

    public init(
        onInput: @escaping @Sendable (Data) -> Void = { _ in },
        onResize: @escaping @Sendable (TerminalSize) -> Void = { _ in }
    ) {
        self.onInput = onInput
        self.onResize = onResize
    }
}

/// §29 Phase 5 protocol — implemented by SwiftTerm in the App target and by
/// test doubles in SharedTests (`MockTerminalEngine` lives in the test
/// target). Keeps ANSI parsing out of Shared.
public protocol TerminalEngine: AnyObject, Sendable {
    var interactionMode: TerminalInteractionMode { get set }
    var size: TerminalSize { get }

    /// Push PTY/agent bytes into the renderer.
    func feed(_ data: Data)
    /// Forward user keystrokes when `interactionMode == .interactive`.
    func sendInput(_ data: Data)
    /// Notify the backend of a viewport resize.
    func resize(to size: TerminalSize)
    /// Snapshot of rendered scrollback for reattachment (opaque to callers).
    func scrollbackSnapshot() -> Data
}
