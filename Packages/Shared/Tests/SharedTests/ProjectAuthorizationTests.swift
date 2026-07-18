//
//  ProjectAuthorizationTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("§12.4 project authorization")
struct ProjectAuthorizationTests {
    private func makeTempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("authorized folder is stored with canonical path")
    func authorizeFolder() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let service = ProjectAuthorizationService(repository: store, inspectGit: { _ in
            ProjectGitMetadata(isGitRepository: false)
        })
        let folder = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try await service.authorizeFolder(at: folder, displayName: "Demo")
        #expect(project.displayName == "Demo")
        #expect(project.canonicalPath == folder.path)
        #expect(try await service.isPathAuthorized(folder.path))
    }

    @Test("project removal invalidates access")
    func removalInvalidatesAccess() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let service = ProjectAuthorizationService(repository: store, inspectGit: { _ in
            ProjectGitMetadata(isGitRepository: false)
        })
        let folder = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try await service.authorizeFolder(at: folder)
        #expect(try await service.isPathAuthorized(folder.path))
        try await service.removeProject(id: project.id)
        #expect(try await service.isPathAuthorized(folder.path) == false)
        #expect(try await service.authorizedProject(containing: folder.path) == nil)
    }

    @Test("launchpad data includes recents and favorites")
    func launchpadData() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let service = ProjectAuthorizationService(repository: store, inspectGit: { _ in
            ProjectGitMetadata(isGitRepository: false)
        })
        let first = try makeTempProject()
        let second = try makeTempProject()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        _ = try await service.authorizeFolder(at: first, displayName: "A", isFavorite: true)
        _ = try await service.authorizeFolder(at: second, displayName: "B")

        let agent = RegisteredAgent(
            descriptor: AgentCatalog.all[0],
            installation: AgentInstallation(state: .installed(version: "1"), executablePath: "/tmp/codex"),
            discoveredAt: 1
        )
        let launchpad = try await service.launchpadData(discoveredAgents: [agent])
        #expect(launchpad.favoriteProjects.count == 1)
        #expect(launchpad.recentProjects.count == 2)
        #expect(launchpad.discoveredAgents.count == 1)
    }
}
