//
//  ProcessTerminationTests.swift
//  SharedTests — AgentDeck
//
//  Process-tree termination and bounded version probes: grandchildren must
//  be reaped on terminate, and hung binaries must time out honestly.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
import Darwin

@Suite("process group termination", .serialized)
struct ProcessTerminationTests {
    private func tempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("bounded runner captures output of a healthy probe")
    func boundedRunnerCapturesOutput() throws {
        let output = try BoundedProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["agentdeck-ok"],
            timeoutSeconds: 2
        )
        #expect(output.contains("agentdeck-ok"))
    }

    @Test("bounded runner times out and kills a hung probe")
    func boundedRunnerTimeout() throws {
        let started = Date()
        #expect(throws: BoundedProcessRunner.Failure.self) {
            _ = try BoundedProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["60"],
                timeoutSeconds: 0.3
            )
        }
        // 0.3 s timeout + ≤1 s reap window + slack: must never hang.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("discovery default runner has a hard timeout")
    func discoveryRunnerTimeout() throws {
        let started = Date()
        #expect(throws: AgentDiscoveryError.self) {
            _ = try AgentDiscoveryService.defaultProcessRunner(
                executable: "/bin/sleep",
                arguments: ["60"]
            )
        }
        // 5 s timeout + ≤1 s reap window + slack.
        #expect(Date().timeIntervalSince(started) < 9)
    }

    @Test("PTY terminate reaps the whole process tree, grandchildren included")
    func processTreeKill() async throws {
        try await PTYTestGate.run {
            let directory = try tempDirectory(prefix: "agentdeck-tree")
            let pidFile = directory.appendingPathComponent("grandchild.pid").path
            let script = directory.appendingPathComponent("spawner.sh")
            // Non-interactive shell: no job control, so the background sleep
            // stays in the script's process group.
            let scriptBody = """
            #!/bin/zsh
            /bin/sleep 300 &
            echo $! > \(pidFile)
            wait
            """
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let supervisor = PTYSupervisor(configuration: PTYSupervisorConfiguration(maxConcurrentSessions: 2))
            let sessionID = SessionID.random()
            _ = try await supervisor.launch(
                PTYLaunchRequest(
                    sessionID: sessionID,
                    executable: script.path,
                    workingDirectory: directory.path
                ),
                outputHandler: { _ in }
            )

            var grandchildPID: Int32?
            for _ in 0..<100 {
                if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    grandchildPID = pid
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let pid = try #require(grandchildPID, "grandchild never wrote its pid")
            #expect(kill(pid, 0) == 0, "grandchild should be alive before terminate")

            await supervisor.terminate(sessionID: sessionID)

            var reaped = false
            for _ in 0..<100 {
                // ESRCH: no such process — the group kill reached it.
                if kill(pid, 0) != 0, errno == ESRCH {
                    reaped = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(reaped, "grandchild survived process-group termination")
        }
    }
}
#endif
