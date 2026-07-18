//
//  TransferPipelineTests.swift
//  SharedTests — AgentDeck
//
//  Phase 9 transfer pipeline tests: temp-file lifecycle and hostile filename
//  handling.
//

import Foundation
import Testing
@testable import Shared

@Suite("transfer pipeline")
struct TransferPipelineTests {
    private let now: Int64 = 1_752_793_200_000

    private func makeRootDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "/agentdeck-transfer-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("clipboard text stages into a safe temp file and purges by policy")
    func clipboardLifecycle() async throws {
        let root = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try SQLiteSessionStore.inMemory()
        let manager = AttachmentTransferManager(
            rootDirectory: root,
            repository: store,
            retentionMilliseconds: 1_000,
            nowProvider: { now }
        )

        let staged = try await manager.stageClipboardText("phase-9 clipboard", sessionID: nil)
        #expect(FileManager.default.fileExists(atPath: staged.localPath))
        #expect(staged.reference.mimeType == "text/plain")
        #expect(try await store.listAttachments().count == 1)

        let deleted = try await manager.purgeExpiredAttachments(now: now + 1_001)
        #expect(deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: staged.localPath))
        #expect(try await store.listAttachments().first?.deletedAt == now + 1_001)
    }

    @Test("hostile filenames are sanitized and remain rooted in the temp directory")
    func hostileFilenameSanitization() async throws {
        let root = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try SQLiteSessionStore.inMemory()
        let manager = AttachmentTransferManager(rootDirectory: root, repository: store)

        let staged = try await manager.stageFile(
            named: "../../$(touch /tmp/agentdeck-phase9-pwned).png",
            mimeType: "image/png",
            contents: Data([0x89, 0x50, 0x4E, 0x47]),
            sessionID: nil
        )

        #expect(staged.reference.fileName.contains("..") == false)
        #expect(staged.reference.fileName.contains("$") == false)
        #expect(staged.reference.fileName.contains("/") == false)
        #expect(staged.reference.fileName.contains("(") == false)
        #expect(staged.reference.fileName.contains(")") == false)
        let standardizedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        #expect(staged.localPath.hasPrefix(standardizedRoot + "/"))
        #expect(FileManager.default.fileExists(atPath: staged.localPath))
    }
}
