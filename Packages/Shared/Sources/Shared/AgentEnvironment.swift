//
//  AgentEnvironment.swift
//  Shared — AgentDeck
//
//  Environment allowlist for agent subprocesses. The companion's own
//  environment routinely carries secrets (API tokens, cloud credentials,
//  signing material); child agents must receive only the documented keys
//  below plus each adapter's explicitly declared additions — never the
//  parent's full environment.
//

import Foundation

public enum AgentEnvironment {
    /// Base allowlist applied to every agent subprocess: the minimum a
    /// well-behaved CLI needs to locate executables, a home directory, a
    /// terminal, and temp storage.
    public static let baseAllowedKeys: Set<String> = [
        "PATH",
        "HOME",
        "TERM",
        "LANG",
        "SHELL",
        "TMPDIR"
    ]

    /// Documented runtime additions shared by all first-party adapters:
    /// locale variants and login identity for CLIs that inspect them, plus
    /// the ssh-agent socket Git needs for authenticated remotes. A socket
    /// path is not itself a secret, and coding agents cannot perform
    /// everyday Git-over-SSH work without it.
    public static let runtimeAllowedKeys: Set<String> = [
        "USER",
        "LOGNAME",
        "LC_ALL",
        "LC_CTYPE",
        "SSH_AUTH_SOCK"
    ]

    /// Builds a child environment from `base` (defaults to the current
    /// process environment) keeping only allowlisted keys, caller-declared
    /// `additionalKeys`, and keys matching caller-declared
    /// `additionalPrefixes` (e.g. `ANTHROPIC_` for the Claude adapter only).
    /// `overrides` are always passed through: they are explicitly configured
    /// by the app or the user, not inherited ambient state.
    public static func sanitized(
        base: [String: String] = ProcessInfo.processInfo.environment,
        additionalKeys: Set<String> = [],
        additionalPrefixes: [String] = [],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in base where isAllowed(key, additionalKeys: additionalKeys, additionalPrefixes: additionalPrefixes) {
            result[key] = value
        }
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    /// `sanitized` plus the shared runtime additions (`runtimeAllowedKeys`).
    /// This is the default every adapter launch path should use.
    public static func sanitizedForAgent(
        base: [String: String] = ProcessInfo.processInfo.environment,
        additionalKeys: Set<String> = [],
        additionalPrefixes: [String] = [],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        sanitized(
            base: base,
            additionalKeys: runtimeAllowedKeys.union(additionalKeys),
            additionalPrefixes: additionalPrefixes,
            overrides: overrides
        )
    }

    private static func isAllowed(
        _ key: String,
        additionalKeys: Set<String>,
        additionalPrefixes: [String]
    ) -> Bool {
        if baseAllowedKeys.contains(key) || additionalKeys.contains(key) { return true }
        return additionalPrefixes.contains { key.hasPrefix($0) }
    }
}
