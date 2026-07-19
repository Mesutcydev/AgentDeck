//
//  TerminalSessionModel.swift
//  App — AgentDeck
//
//  §29 Phase 5 session terminal model — feeds SwiftTerm and forwards input.
//  Main-actor isolated (no @unchecked Sendable): network
//  producers call `feed` from any context and the model hops to the main
//  actor. Scrollback is capped at 4 MiB (oldest bytes dropped, truncation
//  flagged) and SwiftTerm feeds are coalesced on a ~50 ms flush.
//

import Foundation
import Observation
import Shared
import SwiftTerm

@MainActor @Observable
final class TerminalSessionModel {
    /// Hard cap on retained PTY scrollback (§23 budget); oldest bytes drop.
    static let scrollbackCapBytes = 4 * 1024 * 1024

    let sessionID: SessionID
    private(set) var interactionMode: TerminalInteractionMode = .interactive
    private(set) var rawOutputText = ""
    /// ANSI-free text for the agent-first Activity conversation. The raw
    /// bytes remain available in Console/Output for exact terminal fidelity.
    private(set) var readableOutputText = ""
    /// Small, bounded conversational tail. Activity renders this instead of
    /// repeatedly slicing the full terminal transcript on every PTY chunk.
    private(set) var activityOutputTail = ""
    private(set) var scrollbackBytes = Data()
    /// True once the 4 MiB cap dropped older output.
    private(set) var scrollbackWasTruncated = false
    /// True once any PTY bytes (live or replay) arrived for this session.
    /// Reattachment replays scrollback via `terminal.attach` (isReplay
    /// chunks), so this flag only distinguishes "never attached" from live.
    private(set) var hasReceivedOutput = false
    /// Last valid geometry reported by SwiftTerm. Retained so reconnecting or
    /// attaching a PTY immediately restores a usable host window size.
    private(set) var terminalColumns = 80
    private(set) var terminalRows = 24

    var onInput: ((Data) -> Void)?
    /// Fired when SwiftTerm reports a size change; wired to `terminal.resize`.
    var onResize: ((Int, Int) -> Void)?

    private weak var terminalView: TerminalView?
    private var pendingFlush = Data()
    private var flushScheduled = false
    private var pendingReadableOutput = ""
    private var readableFlushScheduled = false
    private var textSanitizer = TerminalTextSanitizer()
    private var rawTextDecoder = StreamingUTF8Decoder()

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    func attach(to view: TerminalView) {
        terminalView = view
        // The scrollback replay below already contains any unflushed bytes;
        // drop them from the pending flush so nothing is fed twice.
        pendingFlush.removeAll(keepingCapacity: true)
        if !scrollbackBytes.isEmpty {
            view.feed(byteArray: ArraySlice(scrollbackBytes))
        }
        view.isUserInteractionEnabled = interactionMode == .interactive
    }

    func setInteractionMode(_ mode: TerminalInteractionMode) {
        interactionMode = mode
        terminalView?.isUserInteractionEnabled = mode == .interactive
    }

    /// Producers may call from any actor/queue; bytes land on the main actor.
    nonisolated func feed(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.enqueue(data)
        }
    }

    nonisolated func replayScrollback(_ data: Data) {
        feed(data)
    }

    /// Keystrokes/paste may arrive from any context; they hop to the main
    /// actor and are honored only in interactive mode.
    nonisolated func sendInput(_ data: Data) {
        Task { @MainActor [weak self] in
            guard let self, self.interactionMode == .interactive else { return }
            self.onInput?(data)
        }
    }

    nonisolated func resize(cols: Int, rows: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // SwiftTerm has already resized itself before invoking its
            // delegate. Calling TerminalView.resize here feeds straight back
            // into sizeChanged and can recurse until the app terminates.
            let safeColumns = max(20, cols)
            let safeRows = max(4, rows)
            guard safeColumns != self.terminalColumns || safeRows != self.terminalRows else { return }
            self.terminalColumns = safeColumns
            self.terminalRows = safeRows
            self.onResize?(safeColumns, safeRows)
        }
    }

    func resendCurrentSize() {
        onResize?(terminalColumns, terminalRows)
    }

    // MARK: - Internals

    private func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        hasReceivedOutput = true
        scrollbackBytes.append(data)
        capScrollback()
        appendRawOutput(data)
        pendingFlush.append(data)
        scheduleFlush()
    }

    private func capScrollback() {
        let overflow = scrollbackBytes.count - Self.scrollbackCapBytes
        guard overflow > 0 else { return }
        scrollbackBytes = scrollbackBytes.dropFirst(overflow)
        scrollbackWasTruncated = true
    }

    /// Coalesces bursts of PTY chunks into one SwiftTerm feed per ~50 ms.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushScheduled = false
        guard !pendingFlush.isEmpty else { return }
        let bytes = pendingFlush
        pendingFlush.removeAll(keepingCapacity: true)
        terminalView?.feed(byteArray: ArraySlice(bytes))
    }

    private func appendRawOutput(_ data: Data) {
        let chunk = rawTextDecoder.consume(data)
        rawOutputText.append(chunk)
        pendingReadableOutput.append(textSanitizer.consume(data))
        scheduleReadableFlush()
        if rawOutputText.count > 256_000 {
            rawOutputText = String(rawOutputText.suffix(128_000))
        }
    }

    /// Chat text needs a human-perceivable stream, not one SwiftUI update per
    /// transport packet. Coalescing here prevents layout and scroll work from
    /// scaling with network chunk frequency during long-running commands.
    private func scheduleReadableFlush() {
        guard !readableFlushScheduled else { return }
        readableFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.flushReadableOutput()
        }
    }

    private func flushReadableOutput() {
        readableFlushScheduled = false
        guard !pendingReadableOutput.isEmpty else { return }
        let update = pendingReadableOutput
        pendingReadableOutput.removeAll(keepingCapacity: true)

        readableOutputText.append(update)
        activityOutputTail.append(update)

        if readableOutputText.count > 128_000 {
            readableOutputText = String(readableOutputText.suffix(64_000))
        }
        // Keep enough context for a useful chat response while bounding Text
        // layout to a small, predictable cost. Full history remains in Console.
        if activityOutputTail.count > 24_000 {
            activityOutputTail = String(activityOutputTail.suffix(16_000))
        }
    }
}

/// Streaming ANSI/OSC filter. State is retained across chunks so escape
/// sequences split by transport framing never leak into the chat surface.
private struct TerminalTextSanitizer {
    private enum State { case text, escape, csi, osc, oscEscape }
    private var state: State = .text
    private var textDecoder = StreamingUTF8Decoder()

    mutating func consume(_ data: Data) -> String {
        var clean = Data()
        clean.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .text:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x0D:
                    if clean.last != 0x0A { clean.append(0x0A) }
                case 0x08, 0x00...0x07, 0x0B...0x0C, 0x0E...0x1F, 0x7F:
                    continue
                default:
                    clean.append(byte)
                }
            case .escape:
                if byte == 0x5B {
                    state = .csi
                } else if byte == 0x5D {
                    state = .osc
                } else {
                    state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .osc:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .oscEscape
                }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            }
        }

        return textDecoder.consume(clean)
    }
}

/// Decodes transport chunks without replacing a valid UTF-8 scalar merely
/// because its bytes arrived in different frames. Truly invalid byte
/// sequences still use Swift's replacement-character behavior.
private struct StreamingUTF8Decoder {
    private var incompleteSuffix: [UInt8] = []

    mutating func consume(_ data: Data) -> String {
        guard !data.isEmpty || !incompleteSuffix.isEmpty else { return "" }

        var bytes = incompleteSuffix
        bytes.append(contentsOf: data)
        incompleteSuffix.removeAll(keepingCapacity: true)

        let suffixCount = Self.incompleteUTF8SuffixLength(in: bytes)
        if suffixCount > 0 {
            incompleteSuffix.append(contentsOf: bytes.suffix(suffixCount))
            bytes.removeLast(suffixCount)
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func incompleteUTF8SuffixLength(in bytes: [UInt8]) -> Int {
        guard let last = bytes.last, last >= 0x80 else { return 0 }

        var leadIndex = bytes.count - 1
        var continuationCount = 0
        while leadIndex >= 0,
              (bytes[leadIndex] & 0xC0) == 0x80,
              continuationCount < 3 {
            continuationCount += 1
            leadIndex -= 1
        }

        guard leadIndex >= 0 else {
            return min(bytes.count, continuationCount)
        }

        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: return 0
        }

        let availableLength = bytes.count - leadIndex
        return availableLength < expectedLength ? availableLength : 0
    }
}
