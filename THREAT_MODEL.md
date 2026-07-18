# THREAT_MODEL.md — consolidated threat model

Consolidated 2026-07-18 from SECURITY.md §2 (T1–T18), the Phase 14 findings
log, and the relay hardening wave. SECURITY.md remains the summary; this file
is the working register. Status values:

- **implemented** — mitigation exists in code and is covered by automated tests
- **implemented (design-level)** — mitigation exists in code/design; no
  adversarial or live end-to-end exercise yet
- **partial** — some components exist; named gaps remain
- **planned** — agreed mitigation not yet wired

## 1. Trust boundaries

```
 iPhone (app)  ◀── paired TLS + Ed25519-signed frames (§9/§13) ──▶  Mac (companion)
                                                                       │
                                              local spawn, user's own privileges
                                                                       ▼
                                                              agent executables
                                                                       │
 Mac (companion) ── Ed25519-signed minimal JSON over HTTP/1 ──▶  notification relay
                                                                       │
                                                  (production, NEEDS-HUMAN #2/#7)
                                                                       ▼
                                                                 APNs ──▶ iPhone
```

| Boundary | What crosses | Trust properties |
|---|---|---|
| phone ↔ Mac | Signed §9 frames: session events, approvals, terminal blobs, pairing handshake | Mutual per-device Ed25519 identity; TLS pinned to pairing fingerprint; nonce replay cache; ±30 s timestamps. Mac is the only authenticated boundary. |
| Mac ↔ agent process | argv/env, stdio pipes, PTY bytes, hook files | Agents run as the logged-in user; no shell interpolation; approval engine scopes remote-triggered actions. Executables are discovered, not yet integrity-verified at launch (T15). |
| Mac ↔ relay | §14.3 fixed-schema notify payload only: opaque destination token, event type, session ID, optional project alias, pre-redacted ≤256-char text, expiration, signature | Ed25519 signature per request; forbidden-field hard ceiling with tests; body cap 64 KiB; replay cache until request expiration; per-IP rate limit. Plain HTTP/1 — loopback by default; remote exposure requires TLS termination in front (ADR-0020). |
| relay ↔ APNs | (production only) APNs provider HTTP/2 with `.p8` JWT | Not implemented — delivery simulated (`SimulatedAPNsOutbox`, ring buffer 500). NEEDS-HUMAN #2, #7. |

## 2. Threat register (T1–T18)

| # | Threat | Current mitigation | Status |
|---|---|---|---|
| T1 | Stolen paired phone | Per-device keys in Keychain (`ThisDeviceOnly`); revocation kills credentials + connection (tested Phase 14) | **partial** — iOS app-lock/Face-ID gate not verified in code |
| T2 | Compromised Mac account | Paired-device handshake as boundary; scoped approval engine (Phase 8); audit trail tables | implemented (design-level) |
| T3 | Malicious network (MITM) | TLS + pinning bound to pairing fingerprint; signed frames; Tailscale never trusted alone | implemented (loopback-tested; physical pass NEEDS-HUMAN #10) |
| T4 | Replay attacks | §9 per-frame nonce replay cache + ±30 s tolerance; single-use pairing nonce (120 s); **relay: accepted-request replay cache until `expiration` (added 2026-07-18, 409)** | implemented |
| T5 | QR interception | Fingerprint + 6-word phrase, mutual confirmation; short offer expiry | implemented (Mac-hosted tests only; physical pass NEEDS-HUMAN #10) |
| T6 | Malicious repository | Project allowlist; canonical-path/symlink checks; reversible, previewable integration installs | implemented |
| T7 | Prompt injection in project files | Approval engine gates consequential actions; risk classification; raw-terminal path for uncertain parses | implemented (design-level) |
| T8 | Malicious agent output | Confidence model; approval cards only from ≥0.7-confidence native events; iOS binds to shared models only | implemented |
| T9 | Fake approval card | Approval cards carry provider payload + confidence; critical actions need in-app secure confirmation + device authentication | implemented (interim UI; notification surface inert by design) |
| T10 | Secret leakage via notifications | Pre-redacted text only; §14.3 minimal schema hard ceiling (tested); relay receives no code/output/credentials; relay body cap + signature enforcement (hardened 2026-07-18) | implemented |
| T11 | Clipboard leakage | No continuous clipboard sync by default; optional per-Mac expiring share (§16.1) | implemented (design-level) |
| T12 | Command injection | No shell interpolation anywhere; safe unique attachment filenames; Phase 9 injection tests | implemented |
| T13 | Path traversal | Canonical-path checks; authorized-project boundary; input-size limits | implemented |
| T14 | Symlink escape | Symlink boundary checks on every stored path | implemented |
| T15 | Agent executable replacement | SHA-256 digest + code-signing team recorded at discovery (`AgentDiscovery`/`ExecutableIntegrity.swift`); launch-time re-verification refuses tampered executables (`CompanionSessionService.registerAdapters`) | implemented |
| T16 | Dependency compromise | §26 policy; exact pins (SwiftTerm 1.13.0, Sparkle 2.9.4, SwiftNIO 2.101.3); DEPENDENCIES.md register | implemented (process) |
| T17 | Cloudflare hostname compromise | Hostname never sufficient auth — normal pairing still required | implemented (design-level; tunnel path untested, NEEDS-HUMAN #5) |
| T18 | Lost-device revocation failure | Revocation terminates connection + invalidates credentials; tested Phase 14 | implemented |

Relay-specific hardening added 2026-07-18 (supports T4/T10 and general
abuse resistance): 64 KiB body cap (413), replay cache (409), per-source-IP
rate limit (429 + Retry-After), fail-fast startup without
`RELAY_SIGNING_PUBLIC_KEY`, loopback default bind, bounded simulated outbox.
Tests: `Relay/Tests/RelayTests/RelayHardeningTests.swift`.

## 3. Findings register

| ID | Date | Severity | Description | Disposition |
|---|---|---|---|---|
| F-001 | 2026-07-18 | info | Live APNs + production relay unverified without Apple credentials | needs-human (#2, #7) |
| F-002 | 2026-07-18 | info | WidgetKit extension target + App Group entitlements added; on-device install requires Apple Developer Program (#2) | accepted (architecture complete) |
| F-003 | 2026-07-18 | info | Developer ID notarization pipeline not executed in CI | needs-human (#2); scripts ready |
| F-004 | 2026-07-18 | — | Relay forbidden-field ceiling | fixed@Phase10 (`RelayNotificationTests`, `SecurityHardeningTests`) |
| F-005 | 2026-07-18 | — | Path traversal / project boundary | fixed@Phase4+14 (`PathSafetyTests`, `SecurityHardeningTests`) |
| F-006 | 2026-07-18 | — | Device revocation persistence | fixed@Phase14 (`SecurityHardeningTests`) |
| F-007 | 2026-07-18 | — | Relay: unbounded request body, full-TTL replay window, no rate limit, random-key startup fallback, plaintext UserDefaults signing key, hardcoded companion relay URL | fixed@2026-07-18 wave (`RelayHardeningTests`; Keychain `RelaySigningKeyStore` with migration; configurable relay URL) |
| F-008 | 2026-07-18 | info | `SUPublicEDKey` absent — Sparkle integrated but updates unconfigured | needs-human (real EdDSA appcast signing key; never invent one) |
| F-009 | 2026-07-18 | info | T15 launch-time executable integrity not yet wired into discovery/launch | fixed@2026-07-18 wave (launch-time `ExecutableIntegrityRegistry.verify` in `CompanionSessionService.registerAdapters`; `ExecutableIntegrityTests`) |

No unresolved **critical** findings.
