//
//  AgentEnvironmentTests.swift
//  SharedTests — AgentDeck
//
//  Environment allowlist coverage: inherited secrets must never reach an
//  agent subprocess; only documented keys and declared prefixes survive.
//

import Foundation
import Testing
@testable import Shared

@Suite("agent environment allowlist")
struct AgentEnvironmentTests {
    @Test("NUL environment parser preserves values containing equals signs")
    func parsesNullSeparatedEnvironment() {
        let parsed = AgentEnvironment.parseNullSeparatedEnvironment(
            "PATH=/usr/bin\0ANTHROPIC_AUTH_TOKEN=token=with=equals\0MALFORMED\0=empty\0"
        )

        #expect(parsed == [
            "PATH": "/usr/bin",
            "ANTHROPIC_AUTH_TOKEN": "token=with=equals"
        ])
    }

    private let base: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/test",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "SHELL": "/bin/zsh",
        "TMPDIR": "/tmp/",
        "USER": "test",
        "SSH_AUTH_SOCK": "/tmp/ssh-agent",
        "AWS_SECRET_ACCESS_KEY": "aws-secret",
        "AWS_SESSION_TOKEN": "aws-token",
        "GITHUB_TOKEN": "gh-secret",
        "OPENAI_API_KEY": "sk-openai",
        "ANTHROPIC_API_KEY": "sk-ant",
        "XAI_API_KEY": "xai-secret",
        "MOONSHOT_API_KEY": "moon-secret",
        "SOME_RANDOM_VAR": "random"
    ]

    @Test("base allowlist strips all inherited secrets")
    func baseAllowlistStripsSecrets() {
        let env = AgentEnvironment.sanitized(base: base)
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["TMPDIR"] == "/tmp/")
        for secret in [
            "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "GITHUB_TOKEN",
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY",
            "MOONSHOT_API_KEY", "SOME_RANDOM_VAR", "USER", "SSH_AUTH_SOCK"
        ] {
            #expect(env[secret] == nil, "\(secret) must be stripped")
        }
    }

    @Test("agent variant keeps documented runtime keys but not secrets")
    func agentVariantKeepsRuntimeKeys() {
        let env = AgentEnvironment.sanitizedForAgent(base: base)
        #expect(env["USER"] == "test")
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/ssh-agent")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["OPENAI_API_KEY"] == nil)
    }

    @Test("declared prefixes pass only for the declaring adapter")
    func perAdapterPrefixes() {
        let claudeEnv = AgentEnvironment.sanitizedForAgent(
            base: base,
            additionalPrefixes: ["ANTHROPIC_", "CLAUDE_CODE_"]
        )
        #expect(claudeEnv["ANTHROPIC_API_KEY"] == "sk-ant")
        #expect(claudeEnv["OPENAI_API_KEY"] == nil)
        #expect(claudeEnv["XAI_API_KEY"] == nil)

        let codexEnv = AgentEnvironment.sanitizedForAgent(
            base: base,
            additionalPrefixes: ["OPENAI_", "CODEX_"]
        )
        #expect(codexEnv["OPENAI_API_KEY"] == "sk-openai")
        #expect(codexEnv["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("explicit overrides always pass through")
    func overridesPassThrough() {
        let env = AgentEnvironment.sanitized(
            base: base,
            overrides: ["AGENTDECK_CLAUDE_HOOK_DIR": "/tmp/hooks", "CUSTOM": "1"]
        )
        #expect(env["AGENTDECK_CLAUDE_HOOK_DIR"] == "/tmp/hooks")
        #expect(env["CUSTOM"] == "1")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
    }
}
