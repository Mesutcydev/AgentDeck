//
//  AttachmentTransferCoordinator.swift
//  App — AgentDeck
//
//  Client side of the attachment wire contract: `attachment.init`
//  ({sessionID, name, mimeType, totalBytes, sha256}) →
//  `attachment.init.response` ({transferID, chunkSize}) → chunked
//  `attachment.chunk` ({transferID, index, data-base64, sha256}) →
//  `attachment.finalize` ({transferID}) → `attachment.ack`
//  ({transferID, status, reason?}).
//
//  The contract carries no client correlation ID on `attachment.init`, so
//  transfers are strictly serialized here (FIFO mutex); the composer UI
//  additionally allows only one active upload per session.
//

import CryptoKit
import Foundation
import Shared

/// Outbound attachment frame sender (implemented by IOSRemoteConnectionService).
protocol AttachmentFrameSending: Sendable {
    func sendAttachmentInit(
        sessionID: SessionID,
        name: String,
        mimeType: String,
        totalBytes: Int64,
        sha256: String
    ) async throws
    func sendAttachmentChunk(transferID: String, index: Int64, data: Data, sha256: String) async throws
    func sendAttachmentFinalize(transferID: String) async throws
}

enum AttachmentSendError: Error, Equatable {
    case empty
    /// Client-side 25 MiB pre-check (matches the companion's staging cap).
    case tooLarge(actualBytes: Int64, maximumBytes: Int64)
    case timedOut
    case cancelled
    /// The ack (or init response) rejected the transfer; message is the
    /// companion-provided reason or the raw status when no reason was sent.
    case rejected(String)
}

/// Progress callbacks delivered while a transfer runs.
enum AttachmentSendProgress: Sendable, Equatable {
    case sending(sentBytes: Int64, totalBytes: Int64)
    case finalizing
}

/// One attachment picked in the composer, pre-upload.
struct PickedAttachment: Sendable, Equatable {
    let fileName: String
    let mimeType: String
    let data: Data
}

/// UI-facing upload state for one composer attachment (§29 composer list).
enum AttachmentUploadPhase: Sendable, Equatable {
    case uploading
    case finalizing
    case sent
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .sent, .cancelled, .failed: true
        case .uploading, .finalizing: false
        }
    }
}

struct AttachmentUpload: Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: SessionID
    let fileName: String
    let totalBytes: Int64
    var sentBytes: Int64
    var phase: AttachmentUploadPhase
    let createdAt: Date

    init(
        id: UUID,
        sessionID: SessionID,
        fileName: String,
        totalBytes: Int64,
        sentBytes: Int64,
        phase: AttachmentUploadPhase,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.sentBytes = sentBytes
        self.phase = phase
        self.createdAt = createdAt
    }
}

/// Idempotent continuation box: a response and a timeout/cancellation may
/// race to resume the same continuation; only the first wins.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Serializes and drives attachment uploads over the live connection.
actor AttachmentTransferCoordinator {
    /// Client-side 25 MiB pre-check limit (25 * 1024 * 1024).
    static let maximumAttachmentBytes: Int64 = 25 * 1_024 * 1_024
    /// Chunks are clamped so base64 payload + signed envelope stay well
    /// under the 1 MiB frame cap (256 KiB raw ≈ 342 KiB base64).
    static let maximumChunkBytes = 256 * 1_024
    static let minimumChunkBytes = 1_024
    private static let initTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let ackTimeoutNanoseconds: UInt64 = 120_000_000_000

    private let sender: any AttachmentFrameSending
    private var initBox: ContinuationBox<AttachmentInitResponse>?
    private var ackBox: ContinuationBox<AttachmentAck>?
    private var cancelRequested = false
    /// FIFO mutex: one transfer at a time (no client correlation ID on the
    /// wire, so concurrent inits could not be matched to responses).
    private var transferLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(sender: any AttachmentFrameSending) {
        self.sender = sender
    }

    /// Routes an inbound `attachment.init.response` to the pending transfer.
    func handleInitResponse(_ response: AttachmentInitResponse) {
        initBox?.resume(returning: response)
    }

    /// Routes an inbound `attachment.ack` to the pending transfer.
    func handleAck(_ ack: AttachmentAck) {
        ackBox?.resume(returning: ack)
    }

    /// Cancels the active transfer: pending responses fail immediately and
    /// the chunk loop stops before the next chunk. The contract has no
    /// `attachment.cancel` frame, so the companion is simply abandoned.
    func cancelActiveTransfer() {
        cancelRequested = true
        initBox?.resume(throwing: AttachmentSendError.cancelled)
        ackBox?.resume(throwing: AttachmentSendError.cancelled)
    }

    /// Runs one full transfer. Serialized with any in-flight transfer.
    func send(
        sessionID: SessionID,
        attachment: PickedAttachment,
        progress: @Sendable (AttachmentSendProgress) -> Void
    ) async throws {
        await acquireTransferLock()
        defer { releaseTransferLock() }

        guard !attachment.data.isEmpty else {
            throw AttachmentSendError.empty
        }
        let totalBytes = Int64(attachment.data.count)
        guard totalBytes <= Self.maximumAttachmentBytes else {
            throw AttachmentSendError.tooLarge(
                actualBytes: totalBytes,
                maximumBytes: Self.maximumAttachmentBytes
            )
        }
        cancelRequested = false

        let initBox = ContinuationBox<AttachmentInitResponse>()
        self.initBox = initBox
        defer { self.initBox = nil }
        try await sender.sendAttachmentInit(
            sessionID: sessionID,
            name: attachment.fileName,
            mimeType: attachment.mimeType,
            totalBytes: totalBytes,
            sha256: Self.sha256Hex(attachment.data)
        )
        let response = try await awaitValue(
            initBox,
            timeoutNanoseconds: Self.initTimeoutNanoseconds
        )
        try throwIfCancelled()

        let chunkSize = min(
            max(response.chunkSize, Self.minimumChunkBytes),
            Self.maximumChunkBytes
        )
        var offset = 0
        var index: Int64 = 0
        while offset < attachment.data.count {
            try throwIfCancelled()
            let end = min(offset + chunkSize, attachment.data.count)
            let chunk = Data(attachment.data[offset..<end])
            try await sender.sendAttachmentChunk(
                transferID: response.transferID,
                index: index,
                data: chunk,
                sha256: Self.sha256Hex(chunk)
            )
            offset = end
            index += 1
            progress(.sending(sentBytes: Int64(offset), totalBytes: totalBytes))
        }

        progress(.finalizing)
        let ackBox = ContinuationBox<AttachmentAck>()
        self.ackBox = ackBox
        defer { self.ackBox = nil }
        try await sender.sendAttachmentFinalize(transferID: response.transferID)
        let ack = try await awaitValue(
            ackBox,
            timeoutNanoseconds: Self.ackTimeoutNanoseconds
        )
        try throwIfCancelled()
        guard ack.isAccepted else {
            throw AttachmentSendError.rejected(ack.reason ?? ack.status)
        }
    }

    // MARK: - Internals

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func throwIfCancelled() throws {
        if cancelRequested {
            throw AttachmentSendError.cancelled
        }
    }

    /// Awaits a response continuation with a hard timeout; whichever fires
    /// first wins (the box resumes idempotently).
    private func awaitValue<T: Sendable>(
        _ box: ContinuationBox<T>,
        timeoutNanoseconds: UInt64
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        box.install(continuation)
                    }
                } onCancel: {
                    box.resume(throwing: CancellationError())
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                box.resume(throwing: AttachmentSendError.timedOut)
                throw AttachmentSendError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AttachmentSendError.timedOut
            }
            return first
        }
    }

    private func acquireTransferLock() async {
        if !transferLocked {
            transferLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseTransferLock() {
        if waiters.isEmpty {
            transferLocked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
