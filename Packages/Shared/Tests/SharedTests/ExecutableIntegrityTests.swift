//
//  ExecutableIntegrityTests.swift
//  SharedTests — AgentDeck
//
//  Launch-time integrity: a binary replaced after discovery must be refused.
//

import Foundation
import Testing
@testable import Shared

#if os(macOS)
@Suite("executable integrity", .serialized)
struct ExecutableIntegrityTests {
    private func makeExecutable(contents: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("agent.sh")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test("fingerprint is stable and unsigned scripts yield a nil team")
    func fingerprintStable() throws {
        let path = try makeExecutable(contents: "#!/bin/zsh\necho v1\n")
        let first = try ExecutableIntegrity.fingerprint(atPath: path)
        let second = try ExecutableIntegrity.fingerprint(atPath: path)
        #expect(first == second)
        #expect(first.sha256.count == 64)
        #expect(first.codeSigningTeam == nil)
    }

    @Test("tampered executable fails verification")
    func tamperRejected() throws {
        let path = try makeExecutable(contents: "#!/bin/zsh\necho v1\n")
        let baseline = try ExecutableIntegrity.fingerprint(atPath: path)
        try "#!/bin/zsh\necho pwned\n".write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: ExecutableIntegrityError.self) {
            try ExecutableIntegrity.verify(atPath: path, against: baseline)
        }
        do {
            try ExecutableIntegrity.verify(atPath: path, against: baseline)
            Issue.record("expected fingerprint mismatch")
        } catch ExecutableIntegrityError.fingerprintMismatch(let mismatchPath, let expected, let actual) {
            #expect(mismatchPath == path)
            #expect(expected == baseline.sha256)
            #expect(actual != baseline.sha256)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("registry refuses launch without a recorded baseline")
    func missingBaselineRefused() throws {
        let registry = ExecutableIntegrityRegistry()
        let path = try makeExecutable(contents: "#!/bin/zsh\necho v1\n")
        #expect(throws: ExecutableIntegrityError.baselineMissing(path: path)) {
            try registry.verify(executableAtPath: path)
        }
    }

    @Test("registry accepts recorded binary and rejects post-recording tamper")
    func registryVerify() throws {
        let registry = ExecutableIntegrityRegistry()
        let path = try makeExecutable(contents: "#!/bin/zsh\necho v1\n")
        registry.record(try ExecutableIntegrity.fingerprint(atPath: path))
        try registry.verify(executableAtPath: path)

        try "#!/bin/zsh\necho replaced\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ExecutableIntegrityError.self) {
            try registry.verify(executableAtPath: path)
        }
    }

    @Test("unreadable path fails honestly")
    func unreadable() {
        #expect(throws: ExecutableIntegrityError.self) {
            _ = try ExecutableIntegrity.fingerprint(atPath: "/nonexistent/agentdeck-nope")
        }
    }
}
#endif
