//
//  GitDiffMirror.swift
//  Companion — AgentDeck
//
//  §29 diff mirroring: runs `git diff HEAD` inside an authorized project
//  and maps the result onto the §9 DiffContent wire payload. Stdout is
//  redirected to a temp file — never a pipe — because BoundedProcessRunner
//  reads after exit, and any diff larger than the pipe buffer would park
//  the writer until the timeout kills it. Arguments are passed positionally
//  (no shell), so a hostile project path cannot inject commands.
//

import Foundation
import Shared

enum GitDiffMirrorError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case exitStatus(Int32)
}

enum GitDiffMirror {
    /// §9 byte-cap contract: clients may request 64 KiB…2 MiB; the default
    /// is 512 KiB. Values outside the range are clamped, never rejected.
    static func clampedCap(_ requested: Int?) -> Int {
        min(2 * 1024 * 1024, max(64 * 1024, requested ?? 512 * 1024))
    }

    /// Blocking by design — call from a detached task. Throws honestly on
    /// launch failure, timeout (15 s wall clock), or non-zero git exit.
    static func diffHEAD(sessionID: SessionID, projectPath: String, maxBytes: Int) throws -> DiffContent {
        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agentdeck-diff-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw GitDiffMirrorError.launchFailed("unable to create diff scratch file")
        }
        defer { try? fileManager.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectPath, "diff", "HEAD", "--no-color", "--", "."]
        process.environment = AgentEnvironment.sanitizedForAgent()
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitDiffMirrorError.launchFailed(error.localizedDescription)
        }
        ProcessGroupTerminator.makeGroupLeader(processIdentifier: process.processIdentifier)

        let deadline = Date().addingTimeInterval(15)
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
            // Bounded moment for the SIGKILL escalation to reap the tree.
            let reapDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < reapDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw GitDiffMirrorError.timedOut
        }
        // `git diff` exits 0 with or without differences; anything else is
        // an honest failure (not a repository, corrupt index, …).
        guard process.terminationStatus == 0 else {
            throw GitDiffMirrorError.exitStatus(process.terminationStatus)
        }

        let full = try Data(contentsOf: outputURL)
        let truncated = full.count > maxBytes
        var slice = truncated ? full.prefix(maxBytes) : full
        if truncated, let lastNewline = slice.lastIndex(of: 0x0A) {
            // Cut on a line boundary so the mirrored text never ends
            // mid-escape-sequence or mid-UTF8-scalar.
            slice = slice.prefix(through: lastNewline)
        }
        let text = String(decoding: slice, as: UTF8.self)

        // A capped diff can end mid-file; the parser then fails honestly
        // and we fall back to an empty summary with the raw text intact.
        let document = try? UnifiedDiffParser.parse(text)
        let files = document?.files.map {
            DiffFileSummary(
                path: $0.changedFile.path,
                additions: Int($0.changedFile.additions),
                deletions: Int($0.changedFile.deletions)
            )
        } ?? []

        return DiffContent(
            sessionID: sessionID,
            unifiedDiff: text,
            files: files,
            truncated: truncated
        )
    }
}
