//
//  ProjectAuthorization.swift
//  Shared — AgentDeck
//
//  §12.4 / §29 Phase 4 project authorization: folder picker results become
//  canonical, symlink-checked project profiles in the §12.5 store. Removal
//  immediately invalidates access checks.
//

import Foundation

#if os(macOS)

public enum ProjectAuthorizationError: Error, Equatable {
    case notAuthorized(ProjectID)
    case pathSafety(PathSafetyError)
    case gitInspectionFailed(String)
}

/// Git metadata captured at authorization time (best-effort).
public struct ProjectGitMetadata: Sendable, Equatable {
    public var root: String?
    public var branch: String?
    public var isGitRepository: Bool
    public var isWorktree: Bool

    public init(
        root: String? = nil,
        branch: String? = nil,
        isGitRepository: Bool = false,
        isWorktree: Bool = false
    ) {
        self.root = root
        self.branch = branch
        self.isGitRepository = isGitRepository
        self.isWorktree = isWorktree
    }
}

public struct ProjectAuthorizationService {
    public typealias GitInspector = @Sendable (_ projectRoot: String) throws -> ProjectGitMetadata

    private let repository: any SessionRepository
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Int64
    private let inspectGit: GitInspector

    public init(
        repository: any SessionRepository,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow },
        inspectGit: @escaping GitInspector = ProjectAuthorizationService.defaultGitInspector
    ) {
        self.repository = repository
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.inspectGit = inspectGit
    }

    /// Authorizes a user-selected folder (native picker supplies the URL).
    public func authorizeFolder(
        at url: URL,
        displayName: String? = nil,
        preferredAgent: AgentIdentifier? = nil,
        preferredModel: String? = nil,
        defaultPermissionProfile: String? = nil,
        isFavorite: Bool = false
    ) async throws -> ProjectRecord {
        let canonical = try PathSafety.canonicalPath(for: url, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathSafetyError.notDirectory(canonical)
        }
        let git = (try? inspectGit(canonical)) ?? ProjectGitMetadata()
        let name = displayName ?? url.lastPathComponent
        let now = nowProvider()
        let profile = ProjectRecord(
            id: .random(),
            displayName: name,
            canonicalPath: canonical,
            createdAt: now,
            lastOpenedAt: now,
            gitRoot: git.root,
            branch: git.branch,
            preferredAgent: preferredAgent,
            preferredModel: preferredModel,
            defaultPermissionProfile: defaultPermissionProfile,
            lastSessionID: nil,
            isFavorite: isFavorite,
            isWorktree: git.isWorktree,
            isGitRepository: git.isGitRepository,
            authorizedAt: now
        )
        try await repository.insertProject(profile)
        return profile
    }

    /// Re-authorizes an existing project after the user re-picks the folder.
    public func reauthorizeProject(
        id: ProjectID,
        at url: URL
    ) async throws -> ProjectRecord {
        guard var existing = try await repository.project(id: id) else {
            throw ProjectAuthorizationError.notAuthorized(id)
        }
        let canonical = try PathSafety.canonicalPath(for: url, fileManager: fileManager)
        let git = (try? inspectGit(canonical)) ?? ProjectGitMetadata()
        existing.canonicalPath = canonical
        existing.gitRoot = git.root
        existing.branch = git.branch
        existing.isGitRepository = git.isGitRepository
        existing.isWorktree = git.isWorktree
        existing.authorizedAt = nowProvider()
        existing.lastOpenedAt = nowProvider()
        try await repository.updateProject(existing)
        return existing
    }

    public func removeProject(id: ProjectID) async throws {
        try await repository.deleteProject(id: id)
    }

    public func markOpened(id: ProjectID) async throws {
        guard var project = try await repository.project(id: id) else {
            throw ProjectAuthorizationError.notAuthorized(id)
        }
        project.lastOpenedAt = nowProvider()
        try await repository.updateProject(project)
    }

    public func setFavorite(id: ProjectID, favorite: Bool) async throws {
        guard var project = try await repository.project(id: id) else {
            throw ProjectAuthorizationError.notAuthorized(id)
        }
        project.isFavorite = favorite
        try await repository.updateProject(project)
    }

    /// Returns whether `path` falls inside any authorized project root.
    public func isPathAuthorized(_ path: String) async throws -> Bool {
        try await authorizedProject(containing: path) != nil
    }

    public func authorizedProject(containing path: String) async throws -> ProjectRecord? {
        let canonical = try PathSafety.canonicalPath(for: URL(fileURLWithPath: path), fileManager: fileManager)
        let projects = try await repository.listProjects()
        return projects.first { PathSafety.isContained(in: $0.canonicalPath, path: canonical) }
    }

    public func launchpadData(discoveredAgents: [RegisteredAgent]) async throws -> LaunchpadData {
        let projects = try await repository.listProjects()
        return LaunchpadBuilder.build(projects: projects, agents: discoveredAgents)
    }

    public static func defaultGitInspector(projectRoot: String) throws -> ProjectGitMetadata {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else {
            return ProjectGitMetadata(isGitRepository: false)
        }
        let root = try runGit(at: git, arguments: ["-C", projectRoot, "rev-parse", "--show-toplevel"])
        let branch = (try? runGit(at: git, arguments: ["-C", projectRoot, "branch", "--show-current"])) ?? ""
        let gitDir = try? runGit(at: git, arguments: ["-C", projectRoot, "rev-parse", "--git-dir"])
        let isWorktree = gitDir?.contains(".git/worktrees/") == true
        return ProjectGitMetadata(
            root: root,
            branch: branch.isEmpty ? nil : branch,
            isGitRepository: true,
            isWorktree: isWorktree
        )
    }

    private static func runGit(at executable: String, arguments: [String]) throws -> String {
        let output = try AgentDiscoveryService.defaultProcessRunner(executable: executable, arguments: arguments)
        return output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

#endif
