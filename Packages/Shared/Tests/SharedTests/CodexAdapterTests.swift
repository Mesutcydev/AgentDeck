//
//  CodexAdapterTests.swift
//  SharedTests — AgentDeck
//
//  §24 deterministic fake executable tests for the Codex app-server adapter.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("§11.1 Codex adapter", .serialized)
struct CodexAdapterTests {
    private func fixturePath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("Fixtures/test-codex-app-server").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)
        return fixture
    }

    private func tempProjectDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("fixture app-server streams structured events and approval")
    func structuredJourney() async throws {
        try await IntegrationTestQueue.async {
            let fixture = try fixturePath()
            let agent = try #require(AgentIdentifier("com.openai.codex"))
            let adapter = CodexAdapter(identifier: agent, executablePath: fixture)
            let projectID = ProjectID.random()
            let sessionID = SessionID.random()
            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: sessionID,
                projectID: projectID,
                workingDirectory: try tempProjectDirectory(),
                initialPrompt: PromptInput(text: "hello codex fixture")
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
            #expect(events.contains { if case .completed = $0.payload { true } else { false } })
        }
    }

    @Test("malformed provider notification degrades to raw output")
    func uncertainParseDegrades() async throws {
        try await IntegrationTestQueue.async {
            let fixture = try fixturePath()
            let agent = try #require(AgentIdentifier("com.openai.codex"))
            let adapter = CodexAdapter(identifier: agent, executablePath: fixture)
            let stream = try await adapter.launch(configuration: AgentLaunchConfiguration(
                sessionID: SessionID.random(),
                projectID: ProjectID.random(),
                workingDirectory: try tempProjectDirectory()
            ))
            defer { Task { try? await adapter.terminate(session: stream.handle) } }

            try await adapter.send(.prompt(PromptInput(text: "trigger")), to: stream.handle)

            var sawStructured = false
            let deadline = Date().addingTimeInterval(2)
            for await event in stream.events {
                if event.confidence.isApprovalEligible { sawStructured = true }
                if case .approvalRequested(let request) = event.payload {
                    let decision = try ApprovalDecision(choice: .deny, decidedAt: Date.unixMillisecondsNow)
                    try await adapter.resolveApproval(
                        requestID: request.id,
                        decision: decision,
                        in: stream.handle
                    )
                }
                if case .completed = event.payload { break }
                if Date() > deadline { break }
            }
            #expect(sawStructured)
        }
    }
}
#endif
