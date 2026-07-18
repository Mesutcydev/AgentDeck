//
//  Redactor.swift
//  Shared — AgentDeck
//
//  Secret redaction for strings and log payloads (Constitution #8: no
//  secrets in logs, notifications, the relay, analytics, or the session
//  database). Scrubbed shapes:
//   - Bearer tokens (scheme prefix preserved, credential removed)
//   - sk-…-style API keys (sk-, sk_, including vendor-suffixed forms)
//   - key=value / "key": "value" for sensitive keys (password, token, …)
//   - PEM blocks (covers Ed25519/EC/RSA/OpenSSH private-key material),
//     including unterminated BEGIN blocks from truncated logs
//  Redaction errs toward removal: when in doubt, the text is scrubbed.
//  Boundary: raw 32/64-byte Ed25519 keys as bare base64 are
//  indistinguishable from ordinary base64 — they MUST be kept inside
//  PEM/key=value shapes at producers. Noted in SECURITY.md rules.
//

import Foundation

public enum Redactor {
    /// The uniform replacement marker. Contains no secret material.
    public static let replacement = "[REDACTED]"

    // MARK: - Public API

    /// Redacts secret shapes from a string.
    public static func redact(_ text: String) -> String {
        var result = text
        result = Rule.pemUnterminated.apply(to: result)
        result = Rule.pemBlock.apply(to: result)
        result = Rule.bearerToken.apply(to: result)
        result = Rule.apiKey.apply(to: result)
        result = Rule.sensitiveKeyValue.apply(to: result)
        return result
    }

    /// Recursively redacts a JSONValue log payload:
    ///  - object keys that are sensitive have their ENTIRE value replaced
    ///    (regardless of shape),
    ///  - string values are scrubbed with the string rules,
    ///  - arrays and objects recurse.
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(redact(string))
        case .array(let elements):
            return .array(elements.map(redact))
        case .object(let object):
            var redacted: [String: JSONValue] = [:]
            redacted.reserveCapacity(object.count)
            for (key, nested) in object {
                redacted[key] = isSensitiveKey(key) ? .string(replacement) : redact(nested)
            }
            return .object(redacted)
        case .null, .bool, .int:
            return value
        }
    }

    /// Normalized sensitive-key check for JSONValue object keys:
    /// lowercased, `-` mapped to `_`, matched against the sensitive set.
    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeyNames.contains(normalized)
    }

    // MARK: - Sensitive key names

    /// NOTE: "session_id"/"sessionid" are deliberately NOT sensitive —
    /// session identifiers are not secrets (§14.3 explicitly allows them
    /// in relay payloads); "session_token" stays (it is a credential).
    static let sensitiveKeyNames: Set<String> = [
        "password", "passwd", "pwd", "passphrase",
        "secret", "client_secret",
        "token", "access_token", "refresh_token", "id_token", "session_token",
        "api_key", "apikey", "auth", "authorization",
        "private_key", "signing_key", "encryption_key",
        "cookie"
    ]

    // MARK: - Rules (applied in order; each is an immutable, thread-safe NSRegularExpression)

    private enum Rule {
        /// `-----BEGIN ...-----` with no END (truncated log): scrub to end
        /// of string. Applied BEFORE the complete-block rule so a truncated
        /// block can never leak.
        static let pemUnterminated = CompiledRule(
            pattern: #"-----BEGIN [A-Z0-9 ]+-----[^-]*(?:-(?!----)[^-]*)*$"#,
            replacement: "[REDACTED:PEM]"
        )

        /// Complete PEM block (Ed25519/EC/RSA/OpenSSH), any line structure.
        static let pemBlock = CompiledRule(
            pattern: #"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#,
            replacement: "[REDACTED:PEM]"
        )

        /// `Bearer <token>` — scheme preserved, credential removed.
        static let bearerToken = CompiledRule(
            pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            replacement: "$1[REDACTED:TOKEN]"
        )

        /// sk-… / sk_…-style API keys (vendor suffixes included).
        static let apiKey = CompiledRule(
            pattern: #"\bsk[-_][A-Za-z0-9._-]{8,}"#,
            replacement: "[REDACTED:API-KEY]"
        )

        /// key=value for sensitive keys; quoted and unquoted values.
        static let sensitiveKeyValue = CompiledRule(
            pattern: #"(?i)(["']?(?:"# + Redactor.sensitiveKeyPattern + #")["']?\s*[:=]\s*)("[^"]{0,4096}"|'[^']{0,4096}'|[^\s,;&]{1,4096})"#,
            replacement: "$1[REDACTED]"
        )
    }

    /// The sensitive key names as a regex alternation (built once).
    private static let sensitiveKeyPattern: String = {
        sensitiveKeyNames
            .map { $0.replacingOccurrences(of: "_", with: "[_-]") }
            .sorted()
            .joined(separator: "|")
    }()

    private struct CompiledRule: Sendable {
        let expression: NSRegularExpression?
        let replacement: String

        init(pattern: String, replacement: String) {
            self.expression = try? NSRegularExpression(pattern: pattern)
            self.replacement = replacement
        }

        func apply(to text: String) -> String {
            guard let expression else {
                // Fail CLOSED: a broken constant pattern (a programmer
                // error the test suite catches immediately) redacts
                // everything rather than letting one secret through.
                return "[REDACTED:REDACTOR-RULE-FAILURE]"
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.stringByReplacingMatches(
                in: text, range: range, withTemplate: replacement
            )
        }
    }
}
