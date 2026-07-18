//
//  UnifiedDiffTests.swift
//  SharedTests — AgentDeck
//
//  Phase 9 unified diff parsing/generation tests.
//

import Foundation
import Testing
@testable import Shared

@Suite("unified diff")
struct UnifiedDiffTests {
    @Test("parser extracts changed-file list and hunks")
    func parseUnifiedDiff() throws {
        let diff = """
        diff --git a/App/MainTabView.swift b/App/MainTabView.swift
        index 1111111..2222222 100644
        --- a/App/MainTabView.swift
        +++ b/App/MainTabView.swift
        @@ -1,3 +1,4 @@
         import SwiftUI
        +import Shared
         
         struct MainTabView: View {
        """

        let document = try UnifiedDiffParser.parse(diff)
        #expect(document.files.count == 1)
        let file = try #require(document.files.first)
        #expect(file.changedFile.path == "App/MainTabView.swift")
        #expect(file.changedFile.status == .modified)
        #expect(file.changedFile.additions == 1)
        #expect(file.changedFile.deletions == 0)
        #expect(file.hunks.count == 1)
        #expect(file.hunks.first?.lines.contains { $0.kind == .addition && $0.text == "import Shared" } == true)
    }

    @Test("directory diff generation does not execute hostile filenames")
    func diffGenerationHostileFilename() throws {
        let oldRoot = NSTemporaryDirectory() + "/agentdeck-diff-old-\(UUID().uuidString)"
        let newRoot = NSTemporaryDirectory() + "/agentdeck-diff-new-\(UUID().uuidString)"
        let fileManager = FileManager.default
        let sentinelName = "agentdeck-phase9-pwned-\(UUID().uuidString)"
        let sentinel = fileManager.currentDirectoryPath + "/" + sentinelName
        defer {
            try? fileManager.removeItem(atPath: oldRoot)
            try? fileManager.removeItem(atPath: newRoot)
            try? fileManager.removeItem(atPath: sentinel)
        }
        try fileManager.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        let hostileName = "$(touch${IFS}\(sentinelName)).swift"
        try Data("let value = 1\n".utf8).write(
            to: URL(fileURLWithPath: newRoot).appendingPathComponent(hostileName)
        )

        let document = try DirectoryDiffGenerator.diffDirectories(oldRoot: oldRoot, newRoot: newRoot)
        #expect(document.files.count == 1)
        #expect(document.files.first?.changedFile.path == hostileName)
        #expect(document.files.first?.changedFile.status == .added)
        #expect(fileManager.fileExists(atPath: sentinel) == false)
    }
}
