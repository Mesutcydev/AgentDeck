# SECURITY.md — threat model and protections

**Status:** Phase 14 verified (2026-07-18). Protections below were exercised by automated tests in Phase 14; remaining gaps are documented with dispositions.

## 1. Security invariants (Constitution, SPEC §4)

Security outranks features. Mac companion is the only authenticated boundary. No privileged daemon, no root. No public exposure by default (no Funnel, no auto-tunnels). No secrets in logs, notifications, relay, analytics, or the session database. No unrestricted auto-approval. Every third-party integration is explicit, previewable, reversible, non-destructive, versioned.

## 2. Threat model (SPEC §20.1 minimum list)

| # | Threat | Vector | Primary mitigations (spec) |
|---|---|---|---|
| T1 | Stolen paired phone | Physical access to paired device | Face ID/app lock (§20.2); per-device keys in Keychain/Secure Enclave; revocation kills credentials + connection (§13.3); no plaintext long-term secrets (§20.2) |
| T2 | Compromised Mac account | Malware as the user | Agents run as the logged-in user anyway — boundary is the paired-device handshake (§13); approval engine scopes what remote triggers can do (§15); audit trail (§20.2) |
| T3 | Malicious network (MITM) | Untrusted LAN/Wi-Fi | TLS + pinning bound to pairing fingerprint (§13.4 endpoint binding); signed frames (§9); never trust Tailscale alone (§13.4) |
| T4 | Replay attacks | Reused frames/pairing offers | Per-frame nonce + replay cache (§9); ±30 s timestamp tolerance; single-use ≥128-bit pairing nonce, 120 s expiry (§13.2); unit tests §24 |
| T5 | QR interception | Attacker scans/offers QR first | Fingerprint + 6-word verification phrase, mutual confirmation (§13.2); short offer expiry |
| T6 | Malicious repository | Poisoned project files (AGENTS.md, hooks) | Project allowlist + canonical-path/symlink checks (§20.2); agents run with user's own permissions; integration installs are previewable + non-destructive (§19) |
| T7 | Prompt injection inside project files | Agent reads hostile content and acts | Approval engine gates consequential actions (§15); risk classification; raw-terminal path for uncertain parses (§10.4); never fabricate events (Constitution #2) |
| T8 | Malicious agent output | Agent emits fake UI/approval text | Structured-event confidence model (§10.4); approval cards only from ≥0.7-confidence native events; iOS binds only to shared-package models (§9) |
| T9 | Fake approval card | UI spoof / adapter defect | Approval contents include original provider payload + confidence (§15.3); critical actions need Face ID + hold-to-confirm in-app (§15.4) |
| T10 | Secret leakage via notifications | APNs/relay sees sensitive text | Pre-redacted notification text only; relay receives fixed minimal schema (§14.3); "relay never receives" list is a hard ceiling with tests (Phase 10) |
| T11 | Clipboard leakage | Over-broad sync | No continuous clipboard sync by default; optional relay is per-Mac, expiring, clearable (§16.1) |
| T12 | Command injection | Interpolated attachment names / paths | No shell interpolation anywhere (§20.2); attachment pipeline uses safe unique filenames (§16.2); injection tests (Phase 9) |
| T13 | Path traversal | Crafted attachment/diff paths | Canonical-path checks, authorized-project boundary (§20.2); input-size limits |
| T14 | Symlink escape | Project path swapped via symlink | Symlink boundary checks on every stored path (§20.2, Phase 4 constraints) |
| T15 | Agent executable replacement | Binary swapped post-detection | Record code-signing info + version at detection (§12.3); canonical path resolution; re-inspection on launch — digest/team fingerprint recorded at discovery (`AgentDiscovery`/`ExecutableIntegrity.swift`); launch-time re-verification refuses tampered executables (`CompanionSessionService.registerAdapters`) |
| T16 | Dependency compromise | Malicious/typosquatted package | §26 policy: system-first, pinned exact versions, license + maintenance review, no transitive networking/analytics; DEPENDENCIES.md register |
| T17 | Cloudflare hostname compromise | Tunnel endpoint hijacked | Hostname is never sufficient authentication — normal AgentDeck pairing still required (§13.5.3) |
| T18 | Lost-device revocation failure | Revoked phone keeps access | Revocation terminates connection immediately + invalidates credentials (§13.3); lost-device revocation test (Phase 14) |

Additional platform facts: APNs requires a developer-operated relay (§14.3); iOS cannot hold a permanent background WebSocket (§14.1) — both verified in Phase 0 (DECISIONS.md, A9/A10).

## 3. Protections in force by design (SPEC §20.2)

Keychain for private credentials; per-device Curve25519 pairing keys with ephemeral agreement; project allowlist; canonical-path + symlink checks; input-size and message-rate limits; signed protocol messages over JCS-canonical bytes (§9); TLS pinning bound to pairing; redaction utilities (Phase 1); audit trail; secure temp files; no shell interpolation; no hidden analytics; no sensitive notification content; agents run as the logged-in user, never root.

## 4. Secrets-handling rules for all phases

- Never log private keys, pairing nonces, APNs tokens, provider credentials, or frame payloads marked sensitive — OSLog privacy annotations from Phase 1.
- Test fixtures use generated throwaway keys only; no real credentials in the repo or tests (§24: the suite never needs real provider accounts).
- `NEEDS-HUMAN` entries describe *what* credential is needed and *where it goes* — never the credential value itself.
- Producers keep key material inside redactable shapes (PEM blocks, `key=value` fields): bare base64 Ed25519 keys are indistinguishable from ordinary base64 and are outside the Phase 1 Redactor's guaranteed coverage (documented boundary in `Redactor.swift`).

## 5. Findings log (Phase 14)

| ID | Date | Severity | Description | Disposition |
|---|---|---|---|---|
| F-001 | 2026-07-18 | info | Live APNs + production relay unverified without Apple credentials | needs-human (#2, #7) |
| F-002 | 2026-07-18 | info | WidgetKit extension target + App Group entitlements added; on-device install requires Apple Developer Program (#2) | accepted (architecture complete) |
| F-003 | 2026-07-18 | info | Developer ID notarization pipeline not executed in CI | needs-human (#2); scripts ready |
| F-004 | 2026-07-18 | — | Relay forbidden-field ceiling | fixed@Phase10 (`RelayNotificationTests`, `SecurityHardeningTests`) |
| F-005 | 2026-07-18 | — | Path traversal / project boundary | fixed@Phase4+14 (`PathSafetyTests`, `SecurityHardeningTests`) |
| F-006 | 2026-07-18 | — | Device revocation persistence | fixed@Phase14 (`SecurityHardeningTests`) |

No unresolved **critical** findings.
