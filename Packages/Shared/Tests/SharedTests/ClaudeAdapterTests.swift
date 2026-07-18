//
//  ClaudeAdapterTests.swift
//  SharedTests — AgentDeck
//
//  §29 Phase 7 deterministic Claude fixture coverage: settings merge/removal,
//  stream-json approvals + resume, and PTY raw-output fallback.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("§29 Phase 7 Claude adapter", .serialized)
struct ClaudeAdapterTests {
    private func fixturePath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("Fixtures/test-claude").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)
        return fixture
    }

    private func tempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("existing Claude settings survive hook install and removal")
    func settingsSurviveInstallRemoval() async throws {
        let home = try tempDirectory(prefix: "agentdeck-claude-home")
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let original = """
        {
          "permissions": {
            "allow": [
              "Bash(git status)"
            ]
          },
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo existing-notification-hook"
                  }
                ]
              }
            ]
          }
        }
        """
        try (original + "\n").write(to: settingsURL, atomically: true, encoding: .utf8)

        let manager = ClaudeHookManager(configuration: .init(claudeDirectoryPath: claudeDirectory.path))
        try await manager.installHooks(explicitApprovalGranted: true)

        let merged = try readJSONObject(at: settingsURL)
        let permissions = try #require(merged["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow == ["Bash(git status)"])
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolUse.count == 1)
        let managedCommand = ((preToolUse.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        #expect(managedCommand.contains("AGENTDECK_CLAUDE_HOOK_MARKER=phase7"))

        try await manager.removeHooks()

        let restored = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(restored == original + "\n")
        #expect(!(try await manager.managedHookIsInstalled()))
    }

    @Test("stream-json fixture yields approvals and resumes by session id")
    func structuredJourneyAndResume() async throws {
        let fixture = try fixturePath()
            let home = try tempDirectory(prefix: "agentdeck-claude-home")
            let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
            let workingDirectory = try tempDirectory(prefix: "agentdeck-claude-project")
            let agent = try #require(AgentIdentifier("com.anthropic.claude-code"))
            let hookManager = ClaudeHookManager(configuration: .init(claudeDirectoryPath: claudeDirectory.path))
            let adapter = ClaudeAdapter(
                identifier: agent,
                executablePath: fixture,
                hookManager: hookManager,
                hookInstallApprovalGranted: true,
                environmentOverrides: [
                    "HOME": home.path,
                    "AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS": "5"
                ]
            )

            let sessionID = SessionID.random()
            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: sessionID,
                projectID: ProjectID.random(),
                workingDirectory: workingDirectory.path,
                initialPrompt: PromptInput(text: "first turn")
            ))

            var messageTexts: [String] = []
            var approvals = 0
            var completions = 0
            var sentFollowUp = false
            var finished = false
            let deadline = Date().addingTimeInterval(8)

            events: for await event in stream.events {
                switch event.payload {
                case .messageText(let text):
                    messageTexts.append(text.text)
                case .approvalRequested(let request):
                    approvals += 1
                    let decision = try ApprovalDecision(choice: .allowOnce, decidedAt: Date.unixMillisecondsNow)
                    try await adapter.resolveApproval(
                        requestID: request.id,
                        decision: decision,
                        in: stream.handle
                    )
                case .completed:
                    completions += 1
                    if !sentFollowUp {
                        sentFollowUp = true
                        try await adapter.send(.prompt(PromptInput(text: "second turn")), to: stream.handle)
                    }
                    if completions >= 2 {
                        finished = true
                        break events
                    }
                case .failed(let info):
                    Issue.record("Claude turn failed: \(info.message)")
                    finished = true
                    break events
                default:
                    break
                }
                if Date() > deadline {
                    finished = true
                    break events
                }
            }
            #expect(finished)

            try await adapter.terminate(session: stream.handle)

            #expect(approvals == 2)
            #expect(completions == 2)
            #expect(messageTexts.contains("Started: first turn"))
            #expect(messageTexts.contains("Resumed: second turn"))
            #expect(messageTexts.contains(" Approval granted."))
            #expect(try await hookManager.managedHookIsInstalled())
    }

    @Test("PTY fallback surfaces raw terminal output")
    func ptyFallback() async throws {
        try await IntegrationTestQueue.async {
            let fixture = try fixturePath()
            let home = try tempDirectory(prefix: "agentdeck-claude-home")
            let workingDirectory = try tempDirectory(prefix: "agentdeck-claude-project")
            let agent = try #require(AgentIdentifier("com.anthropic.claude-code"))
            let adapter = ClaudeAdapter(
                identifier: agent,
                executablePath: fixture,
                launchMode: .forcePTYFallback,
                environmentOverrides: ["HOME": home.path]
            )

            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: SessionID.random(),
                projectID: ProjectID.random(),
                workingDirectory: workingDirectory.path,
                initialPrompt: PromptInput(text: "fallback turn")
            ))

            var rawOutputs: [RawOutput] = []
            var sawCompleted = false
            let deadline = Date().addingTimeInterval(4)

            for await event in stream.events {
                switch event.payload {
                case .rawOutput(let output):
                    rawOutputs.append(output)
                    #expect(event.confidence == .ptyHeuristic)
                case .completed:
                    sawCompleted = true
                    break
                default:
                    break
                }
                if sawCompleted || Date() > deadline { break }
            }

            try await adapter.terminate(session: stream.handle)

            #expect(sawCompleted)
            #expect(rawOutputs.contains { $0.text.contains("FALLBACK: fallback turn") })
            #expect(rawOutputs.contains { $0.reason == "Claude PTY fallback" })
        }
    }
}
#endif
