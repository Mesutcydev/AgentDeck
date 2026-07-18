//
//  LaunchpadData.swift
//  Shared — AgentDeck
//
//  §29 Phase 4 launchpad payload: recent/favorite authorized projects plus
//  discovered agents for the iOS Home tab (Phase 6+ UI consumes this model).
//

import Foundation

/// Sanitized launch surface data — no secrets, no full paths on iOS cache
/// beyond what the user already authorized on the Mac (§21).
public struct LaunchpadData: Sendable, Equatable {
    public var recentProjects: [ProjectRecord]
    public var favoriteProjects: [ProjectRecord]
    public var discoveredAgents: [RegisteredAgent]

    public init(
        recentProjects: [ProjectRecord],
        favoriteProjects: [ProjectRecord],
        discoveredAgents: [RegisteredAgent]
    ) {
        self.recentProjects = recentProjects
        self.favoriteProjects = favoriteProjects
        self.discoveredAgents = discoveredAgents
    }
}

public enum LaunchpadBuilder {
    public static func build(
        projects: [ProjectRecord],
        agents: [RegisteredAgent],
        recentLimit: Int = 8
    ) -> LaunchpadData {
        let favorites = projects.filter(\.isFavorite).sorted {
            ($0.lastOpenedAt ?? 0) > ($1.lastOpenedAt ?? 0)
        }
        let recents = projects
            .sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
            .prefix(recentLimit)
        return LaunchpadData(
            recentProjects: Array(recents),
            favoriteProjects: favorites,
            discoveredAgents: agents.filter {
                if case .notInstalled = $0.installation.state { return false }
                return true
            }
        )
    }
}
