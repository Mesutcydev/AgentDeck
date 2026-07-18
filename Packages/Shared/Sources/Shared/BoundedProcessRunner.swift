//
//  BoundedProcessRunner.swift
//  Shared — AgentDeck
//
//  Synchronous subprocess runner with a sanitized environment and a hard
//  wall-clock timeout. Used for version/discovery probes where a hung or
//  hostile binary must fail honestly instead of blocking the caller
//  forever.
//

import Foundation

#if os(macOS)

public enum BoundedProcessRunner {
    public enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut(seconds: Double)
        case exitStatus(Int32)
    }

    /// Runs `executable` with a sanitized environment, capturing stdout.
    /// On timeout the whole process tree is terminated and
    /// `Failure.timedOut` is thrown. Output is read after exit, so probes
    /// that emit more than a pipe buffer of output are killed by the
    /// timeout — acceptable for version-style probes, documented here.
    public static func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 5,
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? AgentEnvironment.sanitizedForAgent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        ProcessGroupTerminator.makeGroupLeader(processIdentifier: process.processIdentifier)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                ProcessGroupTerminator.terminateTree(process: process, graceMillis: 500)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if timedOut {
            // Give the SIGKILL escalation a bounded moment to reap the tree.
            let reapDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < reapDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw Failure.timedOut(seconds: timeoutSeconds)
        }
        guard process.terminationStatus == 0 else {
            throw Failure.exitStatus(process.terminationStatus)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
