//
//  PTYSupervisorTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("§12.4 PTY supervisor", .serialized)
struct PTYSupervisorTests {
    @Test("echo command produces output")
    func echoOutput() async throws {
        try await PTYTestGate.run {
            let supervisor = PTYSupervisor(configuration: PTYSupervisorConfiguration(maxConcurrentSessions: 2))
            let sessionID = SessionID.random()
            let temp = FileManager.default.temporaryDirectory
            let outputBox = OutputBox()
            _ = try await supervisor.launch(
                PTYLaunchRequest(
                    sessionID: sessionID,
                    executable: "/bin/echo",
                    arguments: ["agentdeck-pty-ok"],
                    workingDirectory: temp.path
                ),
                outputHandler: { chunk in
                    outputBox.append(chunk)
                }
            )
            for _ in 0..<80 {
                if String(data: outputBox.combined, encoding: .utf8)?.contains("agentdeck-pty-ok") == true {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let combined = String(data: outputBox.combined, encoding: .utf8) ?? ""
            #expect(combined.contains("agentdeck-pty-ok"))
            await supervisor.terminate(sessionID: sessionID)
        }
    }

    @Test("concurrent session limit is enforced")
    func sessionLimit() async throws {
        try await PTYTestGate.run {
            let supervisor = PTYSupervisor(configuration: PTYSupervisorConfiguration(maxConcurrentSessions: 1))
            let temp = FileManager.default.temporaryDirectory
            let first = SessionID.random()
            _ = try await supervisor.launch(
                PTYLaunchRequest(
                    sessionID: first,
                    executable: "/bin/sleep",
                    arguments: ["5"],
                    workingDirectory: temp.path
                ),
                outputHandler: { _ in }
            )
            let second = SessionID.random()
            do {
                _ = try await supervisor.launch(
                    PTYLaunchRequest(
                        sessionID: second,
                        executable: "/bin/echo",
                        arguments: ["blocked"],
                        workingDirectory: temp.path
                    ),
                    outputHandler: { _ in }
                )
                Issue.record("expected session limit error")
            } catch PTYSupervisorError.sessionLimitReached(let limit) {
                #expect(limit == 1)
            }
            await supervisor.terminate(sessionID: first)
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }

    var combined: Data {
        lock.lock()
        defer { lock.unlock() }
        return chunks.reduce(into: Data()) { $0.append($1) }
    }
}
#endif
