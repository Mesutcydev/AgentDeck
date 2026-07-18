//
//  PathSafetyTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("§20.2 path safety")
struct PathSafetyTests {
    @Test("canonical path resolves symlinks in the leaf")
    func canonicalPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let target = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let canonical = try PathSafety.canonicalPath(for: link)
        #expect(canonical == target.path)
        #expect(PathSafety.isContained(in: target.path, path: canonical))
    }

    @Test("paths outside the project root are rejected")
    func boundaryRejection() throws {
        let root = "/tmp/agentdeck-root"
        let outside = "/tmp/agentdeck-outside/file.txt"
        #expect(PathSafety.isContained(in: root, path: root))
        #expect(!PathSafety.isContained(in: root, path: outside))
    }

    @Test("symlink components are detected")
    func symlinkComponent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(PathSafety.pathHasSymlinkComponent(link.path, stoppingAt: base.path))
        let resolvedTarget = try PathSafety.canonicalPath(for: target)
        #expect(!PathSafety.pathHasSymlinkComponent(resolvedTarget, stoppingAt: base.path))
    }
}
