//
//  TerminalStreamBridge.swift
//  Shared — AgentDeck
//
//  §29 Phase 5 helpers for streaming PTY bytes over §9 terminal frames and
//  replaying scrollback on reattachment.
//

import Foundation

public enum TerminalStreamBridge {
    public static func makeOutputFrame(
        sessionID: SessionID,
        data: Data,
        isReplay: Bool = false
    ) -> JSONValue {
        TerminalOutputPayload(sessionID: sessionID, data: data, isReplay: isReplay).toJSONValue()
    }

    public static func makeInputFrame(sessionID: SessionID, data: Data) -> JSONValue {
        TerminalInputPayload(sessionID: sessionID, data: data).toJSONValue()
    }

    public static func parseOutput(_ payload: JSONValue) throws -> TerminalOutputPayload {
        try TerminalOutputPayload(jsonValue: payload)
    }

    public static func parseInput(_ payload: JSONValue) throws -> TerminalInputPayload {
        try TerminalInputPayload(jsonValue: payload)
    }

    /// Replays stored scrollback as a sequence of terminal.output frames.
    public static func replayChunks(
        sessionID: SessionID,
        scrollback: Data,
        chunkSize: Int = 4096
    ) -> [JSONValue] {
        guard !scrollback.isEmpty else { return [] }
        let size = max(256, chunkSize)
        var payloads: [JSONValue] = []
        var offset = 0
        while offset < scrollback.count {
            let end = min(offset + size, scrollback.count)
            let chunk = scrollback.subdata(in: offset..<end)
            payloads.append(makeOutputFrame(sessionID: sessionID, data: chunk, isReplay: true))
            offset = end
        }
        return payloads
    }
}

#if os(macOS)
public actor TerminalSessionStream {
    private let sessionID: SessionID
    private let connection: PeerConnection
    private let scrollback: TerminalScrollbackStore
    /// PTY write hook supplied by the companion supervisor; `forwardInput`
    /// delivers validated keystroke bytes here.
    private let inputHandler: @Sendable (Data) -> Void

    public init(
        sessionID: SessionID,
        connection: PeerConnection,
        scrollback: TerminalScrollbackStore = TerminalScrollbackStore(),
        inputHandler: @escaping @Sendable (Data) -> Void
    ) {
        self.sessionID = sessionID
        self.connection = connection
        self.scrollback = scrollback
        self.inputHandler = inputHandler
    }

    public func replayToPeer() async throws {
        let data = await scrollback.snapshot()
        for payload in TerminalStreamBridge.replayChunks(sessionID: sessionID, scrollback: data) {
            try await connection.send(type: .terminalOutput, payload: payload)
        }
    }

    public func sendOutput(_ data: Data) async throws {
        try await scrollback.append(data)
        let payload = TerminalStreamBridge.makeOutputFrame(sessionID: sessionID, data: data)
        try await connection.send(type: .terminalOutput, payload: payload)
    }

    /// Parses a terminal.input frame and forwards the bytes to the PTY via
    /// the injected handler; frames for other sessions are dropped.
    public func forwardInput(from payload: JSONValue) async throws {
        let input = try TerminalStreamBridge.parseInput(payload)
        guard input.sessionID == sessionID else { return }
        inputHandler(input.data)
    }
}
#endif
