//
//  JSONRPCTimeoutTests.swift
//  SharedTests — AgentDeck
//
//  JSON-RPC continuation safety: a hung agent must fail in-flight calls with
//  a timeout instead of suspending the caller forever, and stop() must
//  resume pending callers.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("JSON-RPC call timeouts", .serialized)
struct JSONRPCTimeoutTests {
    private func silentFixture() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("silent-agent.sh")
        // Never writes anything: every RPC call must time out.
        try "#!/bin/zsh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test("ACP call times out against a hung agent")
    func acpCallTimeout() async throws {
        let client = ACPClient(configuration: .init(
            executablePath: try silentFixture(),
            launchArguments: ["acp"],
            workingDirectory: FileManager.default.temporaryDirectory.path,
            requestTimeoutSeconds: 0.4
        ))
        try client.start()
        defer { client.stop() }

        let started = Date()
        await #expect(throws: ACPClientError.self) {
            _ = try await client.call(method: "initialize")
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Codex call times out against a hung agent")
    func codexCallTimeout() async throws {
        let client = CodexAppServerClient(configuration: .init(
            executablePath: try silentFixture(),
            workingDirectory: FileManager.default.temporaryDirectory.path,
            requestTimeoutSeconds: 0.4
        ))
        try client.start()
        defer { client.stop() }

        let started = Date()
        await #expect(throws: CodexAppServerError.self) {
            _ = try await client.call(method: "initialize")
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("stop resumes pending callers instead of leaking them")
    func stopResumesPending() async throws {
        let client = ACPClient(configuration: .init(
            executablePath: try silentFixture(),
            launchArguments: ["acp"],
            workingDirectory: FileManager.default.temporaryDirectory.path,
            requestTimeoutSeconds: 60
        ))
        try client.start()
        let callTask = Task {
            try await client.call(method: "session/new")
        }
        try await Task.sleep(for: .milliseconds(200))
        client.stop()
        let result = await callTask.result
        #expect(throws: ACPClientError.self) {
            _ = try result.get()
        }
    }
}
#endif
