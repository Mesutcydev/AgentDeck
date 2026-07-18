//
//  RedactionTests.swift
//  SharedTests — AgentDeck
//
//  Redaction tests: every scrubbed shape must leave NO recoverable secret
//  material in the output (Constitution #8), and ordinary text must pass
//  through unmangled.
//

import Foundation
import Testing
@testable import Shared

@Suite("redaction")
struct RedactionTests {
    // MARK: - Bearer tokens

    @Test("bearer tokens are scrubbed, scheme preserved")
    func bearerToken() {
        let secret = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
        let output = Redactor.redact("Authorization: Bearer \(secret)")
        // The Authorization key=value rule and the bearer rule both fire;
        // what matters is that no credential material survives.
        #expect(!output.contains(secret))
        #expect(!output.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(output.contains("[REDACTED"))

        // A bare "Bearer <token>" keeps its scheme for log readability.
        let bare = Redactor.redact("sending Bearer \(secret) upstream")
        #expect(!bare.contains(secret))
        #expect(bare.contains("Bearer [REDACTED:TOKEN]"))
    }

    @Test("lowercase and mixed-case bearer schemes are scrubbed")
    func bearerCaseInsensitive() {
        for input in ["bearer abcdef1234567890", "BEARER abcdef1234567890", "BeArEr abcdef1234567890"] {
            #expect(!Redactor.redact(input).contains("abcdef1234567890"), "\(input)")
        }
    }

    // MARK: - sk- style API keys

    @Test("sk-… API key shapes are scrubbed")
    func apiKeys() {
        let secrets = [
            "sk-abcdefghijklmnopqrstuvwxyz",
            "sk-vendor-api03-AbCdEf123456_-xYz",
            "sk-proj-1234567890abcdef",
            "sk_" + "live_51H7y2KjH3kJh4k5j6h",
            "sk_" + "test_4eC39HqLyjWDarjtT1zdp7dc"
        ]
        for secret in secrets {
            let output = Redactor.redact("using key \(secret) now")
            #expect(!output.contains(secret), "\(secret)")
        }
    }

    // MARK: - key=value for sensitive keys

    @Test("key=value secrets are scrubbed, key name preserved")
    func keyValueSecrets() {
        let cases: [(input: String, secret: String, keyPreserved: String)] = [
            ("password=hunter2", "hunter2", "password="),
            ("PASSWORD = \"sup3r-s3cret\"", "sup3r-s3cret", "PASSWORD"),
            ("api_key=AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE", "api_key="),
            ("{\"client_secret\": \"c2s-s3cret-value\"}", "c2s-s3cret-value", "client_secret"),
            ("access_token: 'tok-abc-123-xyz'", "tok-abc-123-xyz", "access_token"),
            ("Authorization: Bearer tok.jskahsdjk.ashdjkasd", "tok.jskahsdjk.ashdjkasd", "Authorization"),
            ("?session_token=abcdef123456&page=2", "abcdef123456", "session_token=")
        ]
        for (input, secret, keyPreserved) in cases {
            let output = Redactor.redact(input)
            #expect(!output.contains(secret), "\(input) → \(output)")
            #expect(output.contains(keyPreserved), "key name should survive in \(output)")
        }
    }

    @Test("secrets embedded in longer log lines are scrubbed")
    func embeddedSecrets() {
        let line = "2026-07-17T10:00:00Z INFO launching agent env={\"SERVICE_API_KEY\": \"sk-vendor-api03-SECRETVALUE123\"} cwd=/Users/test"
        let output = Redactor.redact(line)
        #expect(!output.contains("sk-vendor-api03-SECRETVALUE123"))
        #expect(!output.contains("SECRETVALUE123"))
        #expect(output.contains("launching agent"))
        #expect(output.contains("cwd=/Users/test"))
    }

    // MARK: - PEM blocks

    @Test("complete PEM blocks are scrubbed")
    func pemBlocks() {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MC4CAQAwBQYDK2VwBCIEIMlF2m5J8Kv8nE4pQp1y5b6d3f8a9s0d7f6g5h4j3k2l
        1q2w3e4r5t6y7u8i9o0p
        -----END PRIVATE KEY-----
        """
        let output = Redactor.redact("key material:\n\(pem)\ndone")
        #expect(!output.contains("MC4CAQAwBQYDK2Vw"))
        #expect(!output.contains("1q2w3e4r5t6y7u8i9o0p"))
        #expect(!output.contains("BEGIN PRIVATE KEY"))
        #expect(output.contains("done"))
    }

    @Test("OpenSSH private key blocks (Ed25519) are scrubbed")
    func openSSHBlock() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBsFXhpYWtlYWtlYWtlYWtlYWtlYWtlYWtlYWtlYWtlYWtlYWt
        -----END OPENSSH PRIVATE KEY-----
        """
        let output = Redactor.redact(pem)
        #expect(!output.contains("b3BlbnNzaC1rZXktdjE"))
        #expect(!output.contains("BEGIN OPENSSH"))
    }

    @Test("unterminated BEGIN blocks are scrubbed to end of string")
    func unterminatedPEM() {
        let truncated = "log line\n-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIMlF2m5J8Kv8nE4"
        let output = Redactor.redact(truncated)
        #expect(!output.contains("MC4CAQAwBQYDK2Vw"))
        #expect(!output.contains("BEGIN PRIVATE KEY"))
        #expect(output.contains("log line"))
    }

    // MARK: - JSONValue payloads

    @Test("sensitive object keys have their entire value replaced at any depth")
    func jsonSensitiveKeys() {
        let payload: JSONValue = .object([
            ("config", .object([
                ("api_key", .string("sk-secret-value-123456")),
                ("nested", .object([
                    ("Authorization", .string("Bearer abc.def.ghi")),
                    ("note", .string("safe text"))
                ]))
            ])),
            ("items", .array([
                .object([("password", .string("hunter2"))]),
                .string("safe")
            ]))
        ])
        let redacted = Redactor.redact(payload)
        let canonical = redacted.canonicalString()
        #expect(!canonical.contains("sk-secret-value-123456"))
        #expect(!canonical.contains("abc.def.ghi"))
        #expect(!canonical.contains("hunter2"))
        #expect(canonical.contains("[REDACTED]"))
        #expect(canonical.contains("safe text"))
        #expect(canonical.contains("\"safe\""))
    }

    @Test("string values inside JSONValue are scrubbed shape-wise")
    func jsonStringValues() {
        let payload: JSONValue = .object([
            ("message", .string("call with Bearer tokenvalue123456 failed")),
            ("log", .string("password=opensesame logged"))
        ])
        let canonical = Redactor.redact(payload).canonicalString()
        #expect(!canonical.contains("tokenvalue123456"))
        #expect(!canonical.contains("opensesame"))
    }

    @Test("isSensitiveKey normalizes case and separators")
    func sensitiveKeyNormalization() {
        #expect(Redactor.isSensitiveKey("password"))
        #expect(Redactor.isSensitiveKey("PASSWORD"))
        #expect(Redactor.isSensitiveKey("api-key"))
        #expect(Redactor.isSensitiveKey("api_key"))
        #expect(Redactor.isSensitiveKey("Authorization"))
        #expect(!Redactor.isSensitiveKey("message"))
        #expect(!Redactor.isSensitiveKey("passport")) // not a secret field
    }

    @Test("session identifiers are NOT redacted — they are not secrets (§14.3)")
    func sessionIdentifiersSurvive() {
        let payload: JSONValue = .object([
            ("sessionID", .string("11111111-2222-3333-4444-555555555555")),
            ("session_token", .string("st-secret-123"))
        ])
        let canonical = Redactor.redact(payload).canonicalString()
        #expect(canonical.contains("11111111-2222-3333-4444-555555555555"))
        #expect(!canonical.contains("st-secret-123"))
        #expect(!Redactor.isSensitiveKey("sessionID"))
        #expect(Redactor.isSensitiveKey("session_token"))
    }

    // MARK: - Safety of ordinary text

    @Test("ordinary text passes through unchanged")
    func noOverRedaction() {
        let ordinary = [
            "The sk is short for Saskatchewan",
            "task-oriented output with 42 items",
            "passwords are a great topic to discuss",
            "tokens: counting words in a sentence",
            "skipping ahead",
            "the bearer of bad news", // no token after "bearer of"
            "BEGIN at the start, END at the end"
        ]
        for text in ordinary {
            #expect(Redactor.redact(text) == text, "over-redacted: \(text)")
        }
    }

    @Test("redaction is idempotent")
    func idempotent() {
        let input = "Bearer abc1234567890 password=hunter2 sk-abcdefgh12345"
        let once = Redactor.redact(input)
        #expect(Redactor.redact(once) == once)
    }

    @Test("a JSONValue with no secrets is unchanged")
    func cleanPayloadUnchanged() {
        let payload: JSONValue = .object([
            ("event", .string("session started")),
            ("count", .int(3)),
            ("ok", .bool(true)),
            ("nested", .array([.string("hello"), .null]))
        ])
        #expect(Redactor.redact(payload) == payload)
    }
}
