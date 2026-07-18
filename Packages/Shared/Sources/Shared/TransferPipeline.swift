//
//  TransferPipeline.swift
//  Shared — AgentDeck
//
//  Phase 9 clipboard/screenshot/file transfer staging with safe temp-file
//  lifecycle. Filenames are sanitized and never interpolated into shell
//  commands (§16.2).
//

import Foundation

public enum AttachmentTransferOrigin: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case clipboardText
    case screenshotPNG
    case fileAttachment
}

public struct StagedAttachment: Sendable, Equatable {
    public let origin: AttachmentTransferOrigin
    public let reference: AttachmentReference
    public let localPath: String
    public let expiresAt: Int64

    public init(
        origin: AttachmentTransferOrigin,
        reference: AttachmentReference,
        localPath: String,
        expiresAt: Int64
    ) {
        self.origin = origin
        self.reference = reference
        self.localPath = localPath
        self.expiresAt = expiresAt
    }
}

public enum AttachmentTransferError: Error, Equatable {
    case emptyContent
    case attachmentTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case escapedRoot(String)
    case ioFailed(String)
}

public actor AttachmentTransferManager {
    private let rootDirectory: URL
    private let repository: any SessionRepository
    private let retentionMilliseconds: Int64
    private let maximumBytes: Int64
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Int64

    public init(
        rootDirectory: String,
        repository: any SessionRepository,
        retentionMilliseconds: Int64 = 3_600_000,
        maximumBytes: Int64 = 25_000_000,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow }
    ) {
        self.rootDirectory = URL(fileURLWithPath: rootDirectory, isDirectory: true)
            .standardizedFileURL
        self.repository = repository
        self.retentionMilliseconds = retentionMilliseconds
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    public func stageClipboardText(
        _ text: String,
        sessionID: SessionID?
    ) async throws -> StagedAttachment {
        try await stageFile(
            named: "clipboard.txt",
            mimeType: "text/plain",
            contents: Data(text.utf8),
            origin: .clipboardText,
            sessionID: sessionID
        )
    }

    public func stageScreenshotPNG(
        _ contents: Data,
        originalFileName: String = "screenshot.png",
        sessionID: SessionID?
    ) async throws -> StagedAttachment {
        try await stageFile(
            named: originalFileName,
            mimeType: "image/png",
            contents: contents,
            origin: .screenshotPNG,
            sessionID: sessionID
        )
    }

    public func stageFile(
        named originalName: String,
        mimeType: String?,
        contents: Data,
        origin: AttachmentTransferOrigin = .fileAttachment,
        sessionID: SessionID?
    ) async throws -> StagedAttachment {
        guard !contents.isEmpty else {
            throw AttachmentTransferError.emptyContent
        }
        guard Int64(contents.count) <= maximumBytes else {
            throw AttachmentTransferError.attachmentTooLarge(
                actualBytes: Int64(contents.count),
                maximumBytes: maximumBytes
            )
        }
        try ensureRootDirectory()

        let id = UUID()
        let safeFileName = Self.safeUniqueFileName(originalName, id: id)
        let targetURL = try fileURL(for: safeFileName)
        do {
            try contents.write(to: targetURL, options: .atomic)
        } catch {
            throw AttachmentTransferError.ioFailed(error.localizedDescription)
        }

        let now = nowProvider()
        let record = AttachmentRecord(
            id: id,
            sessionID: sessionID,
            fileName: safeFileName,
            byteCount: Int64(contents.count),
            mimeType: mimeType,
            createdAt: now
        )
        try await repository.insertAttachment(record)
        return StagedAttachment(
            origin: origin,
            reference: AttachmentReference(
                id: id,
                fileName: safeFileName,
                byteCount: Int64(contents.count),
                mimeType: mimeType
            ),
            localPath: targetURL.path,
            expiresAt: now + retentionMilliseconds
        )
    }

    public func purgeExpiredAttachments(now: Int64 = Date.unixMillisecondsNow) async throws -> Int {
        let attachments = try await repository.listAttachments()
        var deleted = 0
        for attachment in attachments where attachment.deletedAt == nil {
            guard attachment.createdAt + retentionMilliseconds <= now else { continue }
            let targetURL = try fileURL(for: attachment.fileName)
            if fileManager.fileExists(atPath: targetURL.path) {
                do {
                    try fileManager.removeItem(at: targetURL)
                } catch {
                    throw AttachmentTransferError.ioFailed(error.localizedDescription)
                }
            }
            try await repository.markAttachmentDeleted(id: attachment.id, deletedAt: now)
            deleted += 1
        }
        return deleted
    }

    public nonisolated static func sanitizedFileName(_ originalName: String) -> String {
        let normalized = originalName.replacingOccurrences(of: "\\", with: "/")
        let leaf = normalized.split(separator: "/").last.map(String.init) ?? "attachment"
        let stem = (leaf as NSString).deletingPathExtension
        let ext = (leaf as NSString).pathExtension

        func sanitize(_ text: String, allowingDots: Bool) -> String {
            let allowed = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: allowingDots ? "-_." : "-_")
            )
            let mapped = text.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? String(scalar) : "-"
            }.joined()
            let collapsed = mapped.replacingOccurrences(
                of: "-+",
                with: "-",
                options: .regularExpression
            )
            let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            return trimmed.isEmpty ? "attachment" : trimmed
        }

        let safeStem = sanitize(stem.isEmpty ? "attachment" : stem, allowingDots: false)
        let safeExt = sanitize(ext, allowingDots: false)
        return safeExt.isEmpty ? safeStem : "\(safeStem).\(safeExt)"
    }

    public nonisolated static func safeUniqueFileName(_ originalName: String, id: UUID) -> String {
        "\(id.uuidString.lowercased())--\(sanitizedFileName(originalName))"
    }

    private func ensureRootDirectory() throws {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw AttachmentTransferError.ioFailed(error.localizedDescription)
        }
    }

    private func fileURL(for safeFileName: String) throws -> URL {
        let url = rootDirectory.appendingPathComponent(safeFileName, isDirectory: false).standardizedFileURL
        guard url.path.hasPrefix(rootDirectory.path + "/") else {
            throw AttachmentTransferError.escapedRoot(url.path)
        }
        return url
    }
}
