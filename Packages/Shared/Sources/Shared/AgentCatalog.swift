//
//  AgentCatalog.swift
//  Shared — AgentDeck
//
//  §11.1 / §12.3 known agent integrations and safe inspection metadata.
//  Discovery probes only the executable names and version arguments listed
//  here — never arbitrary shell output.
//

import Foundation

/// A known agent integration the companion can discover (§12.3).
public struct AgentDescriptor: Sendable, Equatable, Identifiable {
    public var id: AgentIdentifier
    public var displayName: String
    /// Basenames searched in each allowed bin directory (e.g. "codex").
    public var executableNames: [String]
    /// Inspection arguments only — never shell scripts (§12.3).
    public var versionArguments: [String]

    public init(
        id: AgentIdentifier,
        displayName: String,
        executableNames: [String],
        versionArguments: [String] = ["--version"]
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.versionArguments = versionArguments
    }
}

/// Built-in catalog (§11.1 order). Generic agents are user-configured separately.
public enum AgentCatalog {
    private static func id(_ raw: String) -> AgentIdentifier {
        guard let value = AgentIdentifier(raw) else {
            preconditionFailure("invalid catalog id: \(raw)")
        }
        return value
    }

    public static let all: [AgentDescriptor] = [
        AgentDescriptor(
            id: id("com.openai.codex"),
            displayName: "Codex",
            executableNames: ["codex"]
        ),
        AgentDescriptor(
            id: id("com.anthropic.claude-code"),
            displayName: "Claude Code",
            executableNames: ["claude"]
        ),
        AgentDescriptor(
            id: id("com.xai.grok"),
            displayName: "Grok",
            executableNames: ["grok"]
        ),
        AgentDescriptor(
            id: id("com.moonshot.kimi"),
            displayName: "Kimi Code",
            executableNames: ["kimi"]
        ),
        AgentDescriptor(
            id: id("com.anomaly.opencode"),
            displayName: "OpenCode",
            executableNames: ["opencode"]
        )
    ]

    public static func descriptor(for id: AgentIdentifier) -> AgentDescriptor? {
        all.first { $0.id == id }
    }
}

/// Result of locating one catalog agent (§12.3).
public struct RegisteredAgent: Sendable, Equatable, Identifiable {
    public var id: AgentIdentifier { descriptor.id }
    public let descriptor: AgentDescriptor
    public let installation: AgentInstallation
    /// Code-signing team identifier when available.
    public let codeSigningTeam: String?
    public let discoveredAt: Int64

    public init(
        descriptor: AgentDescriptor,
        installation: AgentInstallation,
        codeSigningTeam: String? = nil,
        discoveredAt: Int64
    ) {
        self.descriptor = descriptor
        self.installation = installation
        self.codeSigningTeam = codeSigningTeam
        self.discoveredAt = discoveredAt
    }
}

/// Safe search roots and user overrides (§12.3, Phase 4 constraints).
public struct AgentDiscoveryConfiguration: Sendable, Equatable {
    /// Explicit executable paths configured by the user.
    public var configuredExecutablePaths: [String]
    /// Package-manager bin directories (not the whole home tree).
    public var packageManagerBins: [String]
    /// Standard system bin directories.
    public var systemBins: [String]
    /// PATH entries from the login shell, filtered to exclude home unless allowed.
    public var loginShellPathEntries: [String]
    /// When false (default), no directory under the user's home is searched.
    public var allowHomeDirectorySearch: Bool

    public init(
        configuredExecutablePaths: [String] = [],
        packageManagerBins: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
        systemBins: [String] = ["/usr/bin", "/bin"],
        loginShellPathEntries: [String] = [],
        allowHomeDirectorySearch: Bool = false
    ) {
        self.configuredExecutablePaths = configuredExecutablePaths
        self.packageManagerBins = packageManagerBins
        self.systemBins = systemBins
        self.loginShellPathEntries = loginShellPathEntries
        self.allowHomeDirectorySearch = allowHomeDirectorySearch
    }
}
