//
//  AgentDiscoveryTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("§12.3 agent discovery")
struct AgentDiscoveryTests {
    private func fixturePath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("Fixtures/test-codex").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)
        return fixture
    }

    @Test("configured test agent is discovered with version")
    func configuredAgentDiscovered() throws {
        let fixture = try fixturePath()
        var service = AgentDiscoveryService(
            configuration: AgentDiscoveryConfiguration(
                configuredExecutablePaths: [fixture],
                packageManagerBins: [],
                systemBins: []
            ),
            runProcess: AgentDiscoveryService.defaultProcessRunner
        )
        let codex = AgentCatalog.all[0]
        let results = service.discover(catalog: [codex])
        #expect(results.count == 1)
        guard case .installed(let version) = results[0].installation.state else {
            Issue.record("expected installed fixture, got \(results[0].installation.state)")
            return
        }
        #expect(version.contains("test-codex"))
        let discoveredPath = results[0].installation.executablePath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        let expectedPath = URL(fileURLWithPath: fixture).resolvingSymlinksInPath().path
        #expect(discoveredPath == expectedPath)
        // Discovery pins the executable: unsigned fixture script → nil team,
        // but a SHA-256 baseline must be recorded for launch-time verify.
        #expect(results[0].codeSigningTeam == nil)
        let baseline = ExecutableIntegrityRegistry.shared.baseline(forPath: fixture)
        #expect(baseline?.sha256.count == 64)
        try ExecutableIntegrityRegistry.shared.verify(executableAtPath: fixture)
    }

    @Test("home directory is not searched without permission")
    func noHomeScan() throws {
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex").path
        var service = AgentDiscoveryService(
            configuration: AgentDiscoveryConfiguration(
                configuredExecutablePaths: [],
                packageManagerBins: [],
                systemBins: [],
                loginShellPathEntries: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path],
                allowHomeDirectorySearch: false
            )
        )
        _ = service.discover(catalog: [AgentCatalog.all[0]])
        #expect(!service.lastProbedPaths.contains(homeBin))
        #expect(service.lastProbedPaths.allSatisfy { path in
            !path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/")
        })
    }
}
