//
//  TerminalStreamSupport.swift
//  Companion — AgentDeck
//
//  Glue between PTYSupervisor and PairingServerEngine for §29 terminal
//  streaming: a late-bound engine reference (Configuration hooks are set
//  before the engine exists) and a per-session broadcast sequencer that
//  preserves byte order across async hops.
//

import Foundation
import Shared

/// Late-bound reference to the pairing engine. `terminalStartHandler` is
/// captured by `Configuration` before `PairingServerEngine` is constructed,
/// so PTY output reaches the engine through this box once `start()` runs.
final class TerminalEngineReference: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PairingServerEngine?

    var engine: PairingServerEngine? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ engine: PairingServerEngine) {
        lock.lock()
        stored = engine
        lock.unlock()
    }
}

/// Chains per-session terminal broadcasts: PTY readability handlers fire
/// synchronously on their own queue, but each broadcast is an async hop to
/// the engine actor. Chaining every chunk behind the previous one keeps
/// `terminal.output` frames in spawn order on the wire; a generation
/// counter retires finished tails so the map stays bounded.
final class TerminalBroadcastSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var tails: [SessionID: Task<Void, Never>] = [:]
    private var generations: [SessionID: UInt64] = [:]

    func enqueue(sessionID: SessionID, engine: PairingServerEngine, data: Data) {
        lock.lock()
        let previous = tails[sessionID]
        let generation = (generations[sessionID] ?? 0) &+ 1
        generations[sessionID] = generation
        let task = Task(priority: .utility) {
            await previous?.value
            await engine.broadcastTerminalOutput(sessionID: sessionID, data: data)
        }
        tails[sessionID] = task
        lock.unlock()

        Task { [weak self] in
            await task.value
            self?.clear(sessionID: sessionID, generation: generation)
        }
    }

    private func clear(sessionID: SessionID, generation: UInt64) {
        lock.lock()
        if generations[sessionID] == generation {
            tails[sessionID] = nil
            generations[sessionID] = nil
        }
        lock.unlock()
    }
}
