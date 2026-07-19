import Foundation
import Shared
import Testing
@testable import Companion

@Suite("External provider session discovery")
struct ExternalSessionDiscoveryTests {
    @Test("Claude and Codex metadata are discovered without transcript import")
    func discoversSupportedMetadata() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDirectory = home.appendingPathComponent(".claude/projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let claudeID = "12345678-aaaa-bbbb-cccc-123456789abc"
        let claudeLine = "{\"sessionId\":\"\(claudeID)\",\"cwd\":\"/tmp/claude-project\",\"version\":\"2.1.210\",\"message\":\"must not be retained\"}\n"
        try Data(claudeLine.utf8).write(to: claudeDirectory.appendingPathComponent("session.jsonl"))

        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let codexID = "87654321-dddd-eeee-ffff-cba987654321"
        let codexLine = "{\"id\":\"\(codexID)\",\"cwd\":\"/tmp/codex-project\",\"updated_at\":\"2026-07-19T08:00:00.000Z\"}\n"
        try Data(codexLine.utf8).write(to: codexDirectory.appendingPathComponent("session_index.jsonl"))

        let sessions = ExternalSessionDiscovery(home: home).discover()
        #expect(sessions.count == 2)
        #expect(sessions.contains { $0.providerID == "com.anthropic.claude-code" && $0.externalSessionID == claudeID && $0.canResume })
        #expect(sessions.contains { $0.providerID == "com.openai.codex" && $0.externalSessionID == codexID && $0.canResume })
    }

    @Test("discovery limit is bounded")
    func enforcesLimit() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-discovery-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let lines = (0..<4).map { "{\"id\":\"session-\($0)\"}" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: codexDirectory.appendingPathComponent("session_index.jsonl"))

        #expect(ExternalSessionDiscovery(home: home).discover(limit: 2).count == 2)
    }
}
