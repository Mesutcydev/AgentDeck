//
//  ProjectWorkspace.swift
//  Companion — AgentDeck
//
//  §12.3 / §12.4 project authorization and agent discovery coordinator.
//  Owns the Shared services and exposes UI-ready state to AppState.
//

import Foundation
import Shared

@MainActor @Observable
final class ProjectWorkspace {
    private(set) var projects: [ProjectRecord] = []
    private(set) var discoveredAgents: [RegisteredAgent] = []
    private(set) var launchpad: LaunchpadData = LaunchpadData(recentProjects: [], favoriteProjects: [], discoveredAgents: [])
    private(set) var lastError: String?

    private let repository: any SessionRepository
    private let folderPicker: any FolderPicking
    private var configuredAgentPaths: [String]

    init(
        repository: any SessionRepository,
        folderPicker: any FolderPicking = SystemFolderPicker(),
        configuredAgentPaths: [String] = []
    ) {
        self.repository = repository
        self.folderPicker = folderPicker
        self.configuredAgentPaths = configuredAgentPaths
    }

    func refresh() async {
        do {
            projects = try await repository.listProjects()
            discoveredAgents = discoverAgents()
            launchpad = try await ProjectAuthorizationService(repository: repository)
                .launchpadData(discoveredAgents: discoveredAgents)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func authorizeNewProject() async {
        guard let url = folderPicker.pickFolder() else { return }
        let service = ProjectAuthorizationService(repository: repository)
        do {
            _ = try await service.authorizeFolder(at: url)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeProject(_ project: ProjectRecord) async {
        let service = ProjectAuthorizationService(repository: repository)
        do {
            try await service.removeProject(id: project.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reauthorizeProject(_ project: ProjectRecord) async {
        guard let url = folderPicker.pickFolder() else { return }
        let service = ProjectAuthorizationService(repository: repository)
        do {
            _ = try await service.reauthorizeProject(id: project.id, at: url)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleFavorite(_ project: ProjectRecord) async {
        let service = ProjectAuthorizationService(repository: repository)
        do {
            try await service.setFavorite(id: project.id, favorite: !project.isFavorite)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setConfiguredAgentPaths(_ paths: [String]) {
        configuredAgentPaths = paths
    }

    private func discoverAgents() -> [RegisteredAgent] {
        let pathEntries = Self.agentSearchPathEntries()
        var service = AgentDiscoveryService(
            configuration: AgentDiscoveryConfiguration(
                configuredExecutablePaths: configuredAgentPaths,
                loginShellPathEntries: pathEntries,
                // This authorizes only the explicit PATH directories below.
                // AgentDiscovery still probes known executable basenames and
                // never recursively scans the home directory.
                allowHomeDirectorySearch: true
            )
        )
        return service.discover()
    }

    private static func agentSearchPathEntries() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        // GUI apps do not reliably inherit the user's login-shell PATH.
        // Resolve it with a fixed command and a bounded timeout; no value
        // from the shell is ever executed by AgentDeck.
        let loginEnvironment = [
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        if let shellPath = try? BoundedProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lic", "printf '%s' \"$PATH\""],
            timeoutSeconds: 5,
            environment: loginEnvironment
        ) {
            entries.append(contentsOf: shellPath.split(separator: ":").map(String.init))
        }

        entries.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/.grok/bin",
            "\(home)/.kimi-code/bin",
            "\(home)/.opencode/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "/Applications/ChatGPT.app/Contents/Resources"
        ])
        return Array(Set(entries.filter { !$0.isEmpty })).sorted()
    }
}
