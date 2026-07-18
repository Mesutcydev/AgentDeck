//
//  ACPAdapterTests.swift
//  SharedTests — AgentDeck
//
//  §24 deterministic ACP fixture tests for Kimi/OpenCode adapters.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("§11.1 ACP adapters", .serialized)
struct ACPAdapterTests {
    private func fixturePath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("Fixtures/test-acp").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)
        return fixture
    }

    private func tempProjectDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("ACP fixture streams message, permission, and completion")
    func acpStructuredJourney() async throws {
        try await IntegrationTestQueue.async {
            let fixture = try fixturePath()
            let adapter = try #require(ACPAgentAdapter.kimi(executablePath: fixture))
            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: SessionID.random(),
                projectID: ProjectID.random(),
                workingDirectory: try tempProjectDirectory(),
                initialPrompt: PromptInput(text: "hello acp fixture")
            ))

            var events: [AgentEvent] = []
            let deadline = Date().addingTimeInterval(3)
            for await event in stream.events {
                events.append(event)
                if case .approvalRequested(let request) = event.payload {
                    let decision = try ApprovalDecision(choice: .allowOnce, decidedAt: Date.unixMillisecondsNow)
                    try await adapter.resolveApproval(
                        requestID: request.id,
                        decision: decision,
                        in: stream.handle
                    )
                }
                if case .completed = event.payload { break }
                if Date() > deadline { break }
            }
            try await adapter.terminate(session: stream.handle)

            #expect(events.contains { if case .messageText = $0.payload { true } else { false } })
            #expect(events.contains { if case .approvalRequested = $0.payload { true } else { false } })
            let caps = await adapter.capabilities
            #expect(caps.structuredEvents)
        }
    }

    @Test("OpenCode adapter reuses shared ACP transport")
    func opencodeUsesSharedClient() async throws {
        try await IntegrationTestQueue.async {
            let fixture = try fixturePath()
            let adapter = try #require(ACPAgentAdapter.opencode(executablePath: fixture))
            let profile = await adapter.launchProfile
            let caps = await adapter.capabilities
            #expect(profile == .opencode)
            #expect(caps.streaming)
        }
    }

    @Test("generic agent defaults to terminal mode without structured approvals")
    func genericTerminalMode() async throws {
        let agent = try #require(AgentIdentifier("com.agentdeck.generic.test"))
        let adapter = GenericAgentAdapter(
            identifier: agent,
            configuration: GenericAgentConfiguration(
                executablePath: "/bin/echo",
                arguments: ["AgentDeck generic"]
            )
        )
        let caps = await adapter.capabilities
        #expect(!caps.structuredEvents)
        #expect(!caps.approvals)
        #expect(caps.streaming)
        let installation = await adapter.inspectInstallation()
        #expect(installation.state == .installed(version: "generic"))
    }

    @Test("Grok adapter PTY fallback disables structured approvals")
    func grokPTYFallbackCapabilities() async throws {
        let agent = try #require(AgentIdentifier("com.xai.grok"))
        let adapter = GrokAdapter(
            identifier: agent,
            executablePath: "/bin/echo",
            forcePTYFallback: true
        )
        let caps = await adapter.capabilities
        #expect(!caps.structuredEvents)
        #expect(!caps.approvals)
        #expect(caps.streaming)
    }
}
#endif
