//
//  ClaudeHookHygieneTests.swift
//  SharedTests — AgentDeck
//
//  Hook hardening coverage: the managed PreToolUse command carries a
//  base64 payload (apostrophe-proof), hook request/response files are
//  owner-only (0600), and hook directories are owner-only (0700).
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("§29 Claude hook hygiene", .serialized)
struct ClaudeHookHygieneTests {
    private func tempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }

    /// Installs hooks into a scratch `.claude` directory and extracts the
    /// managed command line from the merged settings.json.
    private func managedCommand() async throws -> (command: String, claudeDirectory: URL) {
        let claudeDirectory = try tempDirectory(prefix: "agentdeck-claude-home")
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let command = try await installedCommand(claudeDirectory: claudeDirectory)
        return (command, claudeDirectory)
    }

    private func installedCommand(claudeDirectory: URL) async throws -> String {
        let manager = ClaudeHookManager(configuration: .init(claudeDirectoryPath: claudeDirectory.path))
        try await manager.installHooks(explicitApprovalGranted: true)
        let data = try Data(contentsOf: claudeDirectory.appendingPathComponent("settings.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let group = try #require(groups.last)
        let entries = try #require(group["hooks"] as? [[String: Any]])
        return try #require(entries.first?["command"] as? String)
    }

    @Test("managed hook command embeds the script as base64, not raw quotes")
    func hookCommandIsBase64() async throws {
        let (command, _) = try await managedCommand()
        #expect(command.contains("AGENTDECK_CLAUDE_HOOK_MARKER=phase7"))
        #expect(command.contains("base64"))
        // The raw script (with its quotes/newlines) must not appear inline.
        #expect(!command.contains("json.load(sys.stdin)"))

        // Decode the trailing payload token and sanity-check the script.
        guard let payloadToken = command.split(separator: " ").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "'")),
              let payloadData = Data(base64Encoded: payloadToken),
              let script = String(data: payloadData, encoding: .utf8) else {
            Issue.record("managed command payload is not valid base64")
            return
        }
        #expect(script.contains("request_id"))
        #expect(script.contains("0o600"))
    }

    @Test("hook request files are created owner-only (0600)")
    func hookRequestFilePermissions() async throws {
        try await IntegrationTestQueue.async {
            let (command, _) = try await managedCommand()
            let hookDirectory = try tempDirectory(prefix: "agentdeck-hook-run")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/local/bin",
                "AGENTDECK_CLAUDE_HOOK_DIR": hookDirectory.path,
                "AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS": "1"
            ]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            stdin.fileHandleForWriting.write(Data("{}\n".utf8))
            stdin.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            let entries = try FileManager.default.contentsOfDirectory(atPath: hookDirectory.path)
            let requestFile = try #require(entries.first { $0.hasPrefix("request-") })
            #expect(try posixPermissions(atPath: hookDirectory.appendingPathComponent(requestFile).path) == 0o600)
        }
    }

    @Test("hook response files are written owner-only (0600)")
    func hookResponseFilePermissions() throws {
        let directory = try tempDirectory(prefix: "agentdeck-hook-response")
        let responseURL = directory.appendingPathComponent("response-abc.json")
        try ClaudeAdapter.writeHookResponseFile(Data("{\"decision\":\"allow\"}".utf8), to: responseURL)
        #expect(try posixPermissions(atPath: responseURL.path) == 0o600)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any]
        #expect(object?["decision"] as? String == "allow")
    }

    @Test("session hook directory is owner-only (0700)")
    func hookDirectoryPermissions() async throws {
        try await IntegrationTestQueue.async {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let fixture = repoRoot.appendingPathComponent("Fixtures/test-claude").path
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)

            let home = try tempDirectory(prefix: "agentdeck-claude-home")
            let working = try tempDirectory(prefix: "agentdeck-claude-project")
            let agent = try #require(AgentIdentifier("com.anthropic.claude-code"))
            let adapter = ClaudeAdapter(
                identifier: agent,
                executablePath: fixture,
                environmentOverrides: [
                    "HOME": home.path,
                    "AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS": "5"
                ]
            )
            let sessionID = SessionID.random()
            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: sessionID,
                projectID: ProjectID.random(),
                workingDirectory: working.path
            ))

            let hookDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentdeck-claude-\(sessionID.wireString)", isDirectory: true)
            #expect(try posixPermissions(atPath: hookDirectory.path) == 0o700)

            try await adapter.terminate(session: stream.handle)
        }
    }
}
#endif
