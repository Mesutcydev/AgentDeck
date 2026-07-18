# AgentDeck — Master Specification

> This document is the durable product and engineering specification. It lives in the repository root as `SPEC.md` and is the single source of truth. Phase prompts reference sections of this document; they do not restate it. If this spec and a phase prompt conflict, this spec wins. If reality and this spec conflict, record the deviation in `DECISIONS.md` and follow §5 (Decision authority and escalation).

**Document version:** 2.1 (restructured; review patches applied 2026-07-17)
**Assumptions verified as of:** 2026-07-17 — every dated claim in §3 must be re-verified at build time.

---

## 1. Context and repository

- Repository location / access: `/Users/air/Developer/AgentDeck` — local git, no remote (filled by Phase 0, 2026-07-17)
- Current state: greenfield — no Xcode project, no sources; only `SPEC.md` + `PHASE_PROMPTS.md` before Phase 0
- Existing targets, packages, and dependencies: none
- What already works: nothing (no code yet)
- Known technical debt: none
- Build machine (ground truth, 2026-07-17): macOS 27.0 (26A5353q, beta host OS), Xcode 26.5 (17F42), Swift 6.3.2, macOS/iOS SDK 26.5. Agent CLIs installed: claude 2.1.210, grok 0.2.99, kimi 0.26.0, opencode 1.17.7; codex not installed (`~/.codex` config dir present). See `ARCHITECTURE.md` for the toolchain pin.

The executing agent must not assume repository contents. Phase 0 produces the authoritative audit; anything this section gets wrong is corrected there.

---

## 2. Product identity

- **Working name:** `AgentDeck`. This name is committed for v1. All user-facing strings, service identifiers, and protocol names derive from a single source: `Packages/Shared/Sources/Shared/ProductNaming.swift` (constant `ProductNaming.name`). Renaming later means editing that one file plus the Xcode target names. Do not scatter the literal string across the codebase.
- **Positioning:** Your Mac's AI coding agents, in your pocket.
- **Value proposition:** Launch, review, approve, and guide Claude Code, Codex, Grok, Kimi, and other Mac-based agents from a native iPhone/iPad interface.
- **The product is not:** an SSH client, a remote terminal, a terminal emulator, or an AI chat wrapper. The defining capability is the shared native control interface across different local agent runtimes.
- **Core user journey:** Pair Mac → select project → tap agent → enter task → review work → approve actions → receive result. The user never manually opens Terminal, types `cd`, launches an agent executable, attaches to tmux, or interprets terminal approval prompts. A full terminal remains available as fallback but never dominates the product.

---

## 3. Dated assumptions — re-verify at build time

The following claims were believed accurate on 2026-07-17. Each is time-sensitive. The agent must re-verify each item during Phase 0 and record the verified result (with source URL and date) in `DECISIONS.md`. Where a claim is false, the affected design section is reworked via ADR before dependent code is written.

| # | Assumption | If false |
|---|---|---|
| A1 | iOS/iPadOS/macOS 26 are the current stable releases; Xcode 26.x is the production toolchain | Update deployment targets and toolchain pin |
| A2 | Xcode 27 / iOS 27 are beta; beta builds are accepted for TestFlight but not App Store | Drop the compatibility branch |
| A3 | Codex exposes an app-server JSON-RPC protocol suitable for structured integration | Use stream JSON or PTY fallback; record decision |
| A4 | Claude Code supports stream JSON output and lifecycle/permission hooks | Use PTY fallback; record decision |
| A5 | Grok's CLI ("Grok Build") supports Agent Client Protocol over stdio | Use PTY fallback; verify official product name |
| A6 | Kimi Code CLI supports ACP or a documented machine-readable interface | Use PTY fallback |
| A7 | OpenCode exposes ACP or a documented machine-readable interface | Use versioned parser + PTY |
| A8 | Tailscale Funnel exposes services publicly (therefore unsuitable as default) | Re-evaluate networking section |
| A9 | Mac App Store sandbox is incompatible with launching/supervising external agent executables | Reconsider Mac App Store distribution |
| A10 | APNs requires a developer-operated relay; no permanent background WebSocket on iOS | Rework §14 |

---

## 4. Non-negotiable invariants (the Constitution)

These rules outrank every other instruction in this document. Every phase prompt repeats them **verbatim** — the list below and the copy in the Phase Prompt Pack are one and the same text; any edit must change both together.

1. Security over features. Conflicts resolve in this order: security > data integrity > native UX > feature completeness > delivery speed.
2. Never fabricate structured events; uncertain parses degrade visibly to the raw terminal (SPEC §10.4).
3. No fake Liquid Glass — system rendering only (SPEC §17).
4. No privileged daemon, no root, no admin requirement for ordinary use.
5. No silent installs, updates, or settings rewrites of third-party agents or user files.
6. No unrestricted global auto-approval anywhere in the product.
7. No public exposure by default: no Tailscale Funnel, no auto-created public tunnels.
8. No secrets in logs, notifications, the relay, analytics, or the session database.
9. The Mac companion is the authenticated boundary; the iPhone never talks directly to agent protocols.
10. Work on THIS phase only. Stop when its acceptance criteria pass.

---

## 5. Decision authority and escalation

### 5.1 The agent decides autonomously
Internal architecture, file layout, naming (below product level), Swift API design, test structure, refactoring, and library use that complies with §26.

### 5.2 The agent must write an ADR first (in `DECISIONS.md`)
- Wire-protocol changes, schema version bumps
- Any new third-party dependency (§26)
- Any deviation from this spec, including false assumptions from §3
- Any acceptance criterion that cannot be met as written

ADR format: `Context / Options considered / Decision / Consequences / Reversible?`.

### 5.3 The agent must stop and mark `NEEDS-HUMAN`
Never guess, stub, or silently skip around these. Log a `## NEEDS-HUMAN` entry in `DECISIONS.md` describing exactly what is needed, then continue with all unblocked work.

- Apple Developer Program credentials (notarization, APNs `.p8` key, TestFlight, App Store Connect)
- Tailscale or Cloudflare account sign-in
- Real provider accounts for agents (outside the test suite, which must not need them — §24)
- Relay hosting/infrastructure choices with cost implications
- Any requirement that appears technically impossible or self-contradictory after an ADR attempt

### 5.4 Priority order under conflict
**Security > data integrity > native UX > feature completeness > delivery speed.**

---

## 6. Platform and deployment targets

- iOS 26+, iPadOS 26+, macOS 26+ (minimums are deliberate — confirmed in §3/A1; revisit only via ADR)
- Swift with strict concurrency checking enabled, `SWIFT_STRICT_CONCURRENCY=complete`
- Swift language version: latest stable supported by the pinned production Xcode toolchain; record the exact version in `ARCHITECTURE.md`
- Production branch builds with the pinned stable Xcode (see `ARCHITECTURE.md` for the pin). A separate `compat/xcode-27` branch tracks beta APIs; production never depends on beta-only APIs. APIs introduced after OS 26 are gated behind availability checks.

## 7. Distribution

| Product | Channel | Requirements |
|---|---|---|
| iOS/iPadOS app | App Store | §17 design compliance, App Review strategy from Phase 0 |
| macOS companion | Product website, direct | Developer ID signed, hardened runtime, notarized, ticket stapled, drag-to-Applications DMG. No PKG in v1. |
| macOS updates | Sparkle 2 | EdDSA-signed appcast over HTTPS; user-prompted updates (auto-download optional). Manual "Check for Updates" fallback always present. |
| Mac App Store edition | Deferred | May be evaluated later as a separate, capability-reduced target; must never constrain the direct edition. |

## 8. Product components

1. Native iOS/iPadOS application
2. Native macOS menu-bar companion (the authenticated boundary and process supervisor)
3. Shared Swift package: protocols, models, wire protocol, security, agent-event definitions
4. Optional WidgetKit extension (status and deep links only)
5. Notification relay for APNs (§14.3)
6. Optional agent skills/hooks/plugin package (§19)

## 9. Wire protocol (v1 — normative)

The shared package implements exactly this envelope. Changes require an ADR and a version bump.

```
Frame := {
  v:      1,                    // protocol version
  type:   String,               // namespaced, e.g. "session.event", "approval.request"
  id:     UUID,                 // unique per frame
  seq:    UInt64,               // per-direction, monotonic from 1
  ack:    UInt64,               // highest contiguous seq received from peer
  cursor: EventCursor?,         // present on event frames; resume position
  ts:     Int64,                // unix milliseconds; accepted within ±30 s
  nonce:  Data (16 bytes),      // random per frame; replay cache keyed on it
  payload: JSONValue,           // versioned Codable payload per type
  sig:    Data                  // Ed25519 over the JCS-canonical encoding of all fields above (see signing rule below)
}
```

- Encoding: compact JSON in v1; binary encoding may be added as v2 via ADR.
- Maximum frame size: 1 MiB. Larger payloads (attachments, diffs) use chunked transfer frames with per-transfer size limits.
- Heartbeat: 15 s interval; peer declared lost after 45 s silence.
- Resume: on reconnect, client sends `session.resume { lastCursor }`; server replays from cursor.
- Every payload type is independently versioned (`payloadV: Int` inside payload).
- **Signing rule:** `sig` is Ed25519 over the RFC 8785 (JCS) canonical UTF-8 encoding of the frame with `sig` absent. All frame numbers are integers (no floats anywhere in v1 frames), which keeps JCS canonicalization unambiguous. Phase 1 ships fixed known-answer test vectors (canonical frame bytes → expected signature) so both platforms pin the exact same encoding; an implementation that cannot reproduce the vectors does not ship.
- `approval.resolve` is idempotent per `requestID`: duplicate or retried resolves (including after reconnect) return the original outcome ("already resolved") and never re-apply a decision.
- The iOS UI never binds to provider-specific JSON; only to shared-package models.

## 10. Shared agent abstraction

### 10.1 Adapter protocol

```swift
public protocol AgentAdapter: Sendable {
    var identifier: AgentIdentifier { get }
    var capabilities: AgentCapabilities { get }

    func inspectInstallation() async -> AgentInstallation
    func inspectAuthentication() async -> AgentAuthenticationState

    func launch(configuration: AgentLaunchConfiguration) async throws -> AgentSessionHandle
    func send(_ input: AgentInput, to session: AgentSessionHandle) async throws
    func resolveApproval(requestID: ApprovalRequestID,
                         decision: ApprovalDecision,
                         in session: AgentSessionHandle) async throws
    func interrupt(session: AgentSessionHandle) async throws
    func resume(session: AgentSessionHandle) async throws
    func terminate(session: AgentSessionHandle) async throws
}
```

### 10.2 Common types
Agent identifier, installation state, authentication state, capabilities, launch configuration, session identifier, session state, prompt input, attachment, event, tool call, command, file operation, diff, approval, completion result, error, recovery action. All event payloads versioned.

### 10.3 Session state machine
`starting → thinking | planning | reading | editing | runningCommand | waitingForApproval | waitingForUser | runningTests → completed | failed | interrupted`, plus orthogonal `disconnected / reconnecting` connectivity states. Illegal transitions are logged as adapter defects.

### 10.4 Adapter confidence (normative definition)
Every structured event carries a confidence value:

| Value | Meaning |
|---|---|
| 1.0 | Native structured protocol event (app-server, ACP, hooks) |
| 0.7 | Versioned stream output parsed with schema match |
| 0.4 | PTY heuristic parse |
| 0.0 | Unknown / unparsed |

Events below 0.7 render with a visible "uncertain" indicator and never auto-populate approval cards. Confidence below 0.7 on an approval-relevant event forces the raw-terminal approval path. Never invent an event the parser did not produce.

## 11. Agent adapters

**Verification gate (from §3):** before each adapter phase, the agent re-verifies the vendor's current structured-interface documentation and records findings (source URL, date, verified capabilities) in `DECISIONS.md`. If the verified interface differs from this section, the ADR amends the plan before code is written.

### 11.1 Implementation order
1. Codex (preferred: app-server JSON-RPC — threads, turns, streamed events, approvals, resume, cancellation, model selection, schema negotiation). Generate schemas from the locally installed version when practical. The iPhone never connects to the Codex experimental WebSocket listener; the companion translates.
2. Claude Code (stream JSON + hooks lifecycle/permission/tool events; PTY mode only when a workflow needs interactive terminal behavior unavailable via stream mode). Hooks install only with explicit user approval; existing settings backed up, merged non-destructively, never replaced wholesale; hooks removable from companion settings.
3. Grok (ACP over stdio; TUI only as raw-terminal fallback).
4. Kimi Code (ACP when available; capability negotiation, skill discovery, session recovery; structured stream or PTY fallback).
5. OpenCode (prefer ACP or documented machine-readable interface; else versioned parser + PTY).
6. Generic agent (user-defined: display name, executable path, arguments, environment, working-directory behavior, optional stream parser, optional approval patterns, optional icon). Generic integrations default to terminal mode. Destructive-action classification must not rely on brittle regex alone.

## 12. macOS companion

### 12.1 Form factor
Menu-bar app (`MenuBarExtra`/`NSStatusItem`), one-time onboarding window, native settings window, small optional status popover. No permanent dashboard; accessory activation policy (no Dock icon) after onboarding.

### 12.2 Background operation
`SMAppService` user-level login item. The background component owns: paired-device connectivity, agent processes, persistent sessions, approval state, event history, notification dispatch, clipboard/file transfer, reconnection state. No WidgetKit-as-service. No fake background modes.

### 12.3 Agent registry
Executable detection via safe explicit locations only: user-configured paths, login-shell PATH resolution, common package-manager locations (not only `/usr/local/bin`), standard system locations. For each executable: resolve canonical path, record version, record code-signing info where available, run only known inspection arguments during detection, never execute output returned by a shell script.

### 12.4 Process supervisor
Owns every agent process: PTY creation, structured stdio, lifecycle, graceful then forced termination (timeout), output backpressure, session persistence, reattachment, crash recovery, orphan detection, configurable concurrent-session limit (default 4, range 1–8). iPhone disconnection never kills a session. Sessions retained until user termination, retention expiry, process exit, or security policy.

### 12.5 Session database
Storage technology is decided by ADR in Phase 0 (candidates: SwiftData vs. SQLite via the system SQLite3 API) and recorded in `DECISIONS.md`; access sits behind a repository abstraction either way. The schema is versioned with explicit migrations — app upgrades must never lose session history (the §24 "app upgrade" integration test covers this). Persists: session metadata, event timeline, approval decisions, attachments, agent resume identifiers, project association, connection history, completion result, redacted diagnostic logs. No raw secrets.

### 12.6 Menu-bar contents and Pause
Status, paired-device count, active-session count, waiting-approval count, Tailscale status, Cloudflare status, Start at Login, **Pause Remote Access**, Pair New Device, Settings, Diagnostics, Quit. Pause rejects new connections, keeps local agent processes (configurable), stops remote event updates, and is clearly indicated.

### 12.7 Settings sections
General, Paired Devices, Projects, Agents, Connections, Permission Policies, Notifications, Security, Diagnostics, About.

## 13. Pairing and transport security

### 13.1 Device identity
CryptoKit Curve25519 signing keys generated per installation; private keys in Keychain; ephemeral key agreement during pairing; rotatable session credentials; unique device IDs not derived from hardware identifiers.

### 13.2 Pairing (normative parameters)
- QR payload contains exactly: `{ v, deviceID, publicKeyFingerprint, endpoint, nonce, protocolVersion }`. No reusable secrets in plaintext.
- Nonce: ≥128-bit random, single-use. Pairing offer expiry: **120 seconds**, with visible countdown.
- Human-readable verification phrase (6-word) plus fingerprint comparison, mutual confirmation, replay protection, protocol-version negotiation, device revocation.
- After pairing both sides store: peer public key, display name, pairing date, last-seen, granted capabilities, revocation state.

### 13.3 Multi-device semantics (v1)
- Up to 5 paired Macs per iOS device; up to 3 paired iOS devices per Mac.
- One WebSocket connection per phone–Mac pair; simultaneous connections to different Macs supported.
- Multiple phones may connect to one Mac concurrently; each sees shared session state; approvals resolve first-come (subsequent resolvers see "already resolved").
- Revoking any device terminates its connection immediately and invalidates its credentials.

### 13.4 Transport
Network.framework + TLS, authenticated WebSocket per §9. Certificate/public-key pinning, application-level request signatures, nonce validation, timestamp tolerance, replay prevention, connection and pairing rate limiting. **Endpoint binding:** the Mac's presented TLS certificate public key must equal the identity key whose fingerprint was exchanged in the QR payload (§13.2), or be signed by it — a certificate first seen after pairing is never trusted. Compression only after security review. **Never trust the network merely because it is Tailscale.**

### 13.5 Connection modes
1. **Tailscale (recommended):** user installs/signs in separately; app detects likely availability, explains shared tailnet requirement, accepts MagicDNS names or Tailscale IPs, tests reachability, reports direct vs. unavailable, avoids depending on Tailscale CLI internals. Never embed or recreate Tailscale. Never use Funnel.
2. **Local network:** Bonjour for onboarding/discovery only; accurate local-network privacy usage description; not required when the user enters a remote address manually.
3. **Cloudflare Tunnel (advanced):** same authenticated WebSocket exposed through the tunnel; requires both Cloudflare Access (or equivalent) and normal AgentDeck pairing. The hostname is never sufficient authentication. Never auto-create a public tunnel without explicit explanation and confirmation.

## 14. iOS background model and notifications

### 14.1 Lifecycle
- **Foreground:** real-time WebSocket; stream events and terminal; resolve approvals; transfer attachments; update state.
- **Background:** persist last acknowledged cursor; gracefully close; rely on APNs; on foreground, reconnect and request events from cursor. A permanent background WebSocket is not a valid design assumption.

### 14.2 Notification categories and actions
Categories: approval required, agent question, session completed, session failed, connection lost, security warning. Actions: open approval, deny, stop session. Direct notification actions only where authenticatable and safe; high-risk approvals always require opening the app (§15).

### 14.3 Notification relay (specified component)

> Infrastructure: APNs requires a developer-operated relay. **Setup steps requiring Apple Developer credentials and hosting are `NEEDS-HUMAN` (§5.3).** If relay infrastructure is unavailable when Phase 10 runs, Phase 10 acceptance is downgraded to APNs sandbox via locally-run relay or a simulated relay, and the limitation is recorded.

- **Reference implementation:** single-binary Swift service (`agentdeck-relay`) in the same repository (`Relay/` target), deployable via provided `Dockerfile` + `docker-compose.yml`. No framework requirement beyond SwiftNIO.
- **Interface:** exactly one endpoint, `POST /v1/notify`, authenticated by Ed25519 signature from a paired companion (companion's relay-signing key registered during companion setup).
- **Relay receives only:** opaque paired-device destination token, event type, session identifier, project display alias (if user permits), pre-redacted notification text, expiration, signature.
- **Relay never receives:** source code, terminal output, full prompts, file contents, environment variables, API keys, complete commands.
- **Behavior:** no persistent user data — only ephemeral rate-limit counters and a ≤24 h retry queue; per-device rate limits; APNs token authentication (`.p8`); no analytics, no logging of payload bodies.
- **Live Activities:** added only after the base notification flow is stable; state limited to project, agent, current activity, elapsed time, waiting status, test status. Never stream raw token output to a Live Activity.

## 15. Approval and policy engine

Central product feature. **No vague global "Always Approve" control may exist anywhere in the product.**

### 15.1 v1 approval choices
Deny · Allow once · Allow this session · Allow this command pattern in this project · Allow read-only actions.

### 15.2 Post-v1 choices (design the rule model for these now; ship UI later)
Allow this tool in this project · Allow until a specific time · Custom rule builder.

### 15.3 Approval request contents
Agent, project, session, tool, exact action, human-readable explanation, files involved, domains involved, working directory, risk classification, reversibility, requested duration, original provider payload, adapter confidence (§10.4).

### 15.4 Risk classifications
Informational · Low · Medium · High · Critical · Unknown.

High/Critical examples: recursive deletion; git force push; deployment; publishing; package installation; reading keychains or secret files; access outside authorized projects; new network domains; system configuration changes; `sudo`; modifying shell startup files or agent settings; creating persistent services; file exfiltration patterns.

Critical actions require: expanded explanation, exact command display, hold-to-confirm, Face ID/device authentication, no notification-only approval, audit-log entry.

### 15.5 Rules
Human-readable, scoped, revocable, searchable, ordered, testable, exportable; project-specific or global. Display style: "Allow `xcodebuild` commands inside SiteAgent until this session ends" — never "Always allow Bash."

## 16. Clipboard, attachments, diffs

### 16.1 Clipboard
Copy response/code block/command/file path/summary/session summary; paste text, image, screenshot-as-bug-context. No continuous clipboard sync by default. Optional relay: explicitly enabled, per-Mac, temporarily disableable, expiring, cleared from temporary storage, protected when locked.

### 16.2 Attachments
On send: encrypt in transit → companion-managed temp directory → validate size/type → safe unique filename → agent receives local path → retention-policy deletion. **Never interpolate an attachment filename into an unescaped shell command.**

### 16.3 Diff viewer
Changed-file list, addition/deletion counts, unified diff, side-by-side on iPad, syntax highlighting, search, jump between changes, copy hunk, open raw diff, ask-agent-to-revise, revert individual file where safe (routed through the §15 approval engine with risk classification — a revert is a phone-initiated write to the user's repo), review before commit. Not a mobile IDE in v1.

## 17. Design — native iOS 26/27 Liquid Glass

Use Apple's real system rendering. Forbidden: large custom blur rectangles, hard-coded translucent backgrounds, stacked materials, artificial reflective gradients, custom fake tab bars, excessive borders, neon glows, glass screenshots, rasterized glass assets.

Required structure: `TabView`, native tab bar, `NavigationStack`, `NavigationSplitView` on iPad, native toolbars/sheets/menus/context menus/alerts/search/detents, system semantic colors and materials, SF Symbols, real glass-effect APIs only where a custom control genuinely needs them. Content is the foreground layer; glass belongs to navigation and controls. No glass on every card.

Main tabs: Home, Sessions, Approvals, Macs, Settings. Compact layouts may combine secondary destinations without custom tab systems.

Accessibility: Dynamic Type, VoiceOver, Reduce Motion, Reduce Transparency, Increased Contrast, Button Shapes, full keyboard navigation on iPad/Mac, Switch Control, meaningful labels, minimum touch targets. **Risk is never communicated by color alone.**

Localization: English only for v1, but all user-facing strings via String Catalogs from day one — zero hard-coded user-facing strings.

## 18. Widget

Optional and secondary. May show: connected Mac, active agents, pending-approval count, last completed session, connection status. Actions deep-link only. The widget never maintains connections, supervises agents, processes terminal output, performs approvals, or stores secrets. App Group storage holds sanitized summary state only.

## 19. Optional agent skills/hooks/plugins

Skills never replace the companion. Optional `AgentDeck` integration package: Claude Code hook templates, Claude skill, Codex instruction template, Kimi skill, generic `AGENTS.md` guidance, event bridge helper. Installation: explicit, previewable, reversible, non-destructive, versioned. Never silently rewrite existing user instruction files.

## 20. Security

### 20.1 Threat model
Produced in Phase 0, before networking code. Must cover at minimum: stolen paired phone; compromised Mac account; malicious network; replay; QR interception; malicious repository; prompt injection inside project files; malicious agent output; fake approval card; secret leakage via notifications; clipboard leakage; command injection; path traversal; symlink escape; agent executable replacement; dependency compromise; Cloudflare hostname compromise; lost-device revocation failure.

### 20.2 Required protections
Keychain for private credentials; Face ID/app lock; per-device pairing keys; device revocation; project allowlist; canonical-path checks; symlink boundary checks; input-size limits; message-rate limits; signed protocol messages; TLS pinning; redaction; audit trail; secure temporary files; no shell interpolation; dependency license review (§26); no hidden analytics; no sensitive notification content; no plaintext long-term session secrets. Agents run as the logged-in user. No root unless a future feature documents an unavoidable need via ADR.

### 20.3 Companion updates
Sparkle 2 (§7) is part of the security posture: EdDSA-signed appcast, HTTPS, and a documented update-verification test in Phase 15.

## 21. Data and privacy

Local-first. The Mac is the source of truth for projects, sessions, terminal history, diffs, attachments, approval policies. iOS stores only paired identity, cached session summaries, offline display data, last event cursor, user settings. Retention controls for session history, terminal output, attachments, diagnostics, audit events. Provide: export diagnostics, clear cache, delete session, revoke device, delete all local data. No source code passes through analytics or the relay.

## 22. Error handling and recovery (required states)

- **Mac unavailable:** last seen, connection method, retry, open Tailscale, diagnostics, change address.
- **Agent missing:** not-installed state, detection locations checked, copy official install command, recheck, configure custom executable.
- **Authentication missing:** sign-in required on Mac, instructions, recheck. Never request provider credentials inside iOS when the agent authenticates locally on the Mac.
- **Session disconnected:** agent continues on Mac, last received event, reconnecting, cached timeline, stop remotely on reconnect.
- **Adapter failure:** structured interface unavailable, raw terminal available, diagnostic identifier, report issue.
- Never silently discard agent output.

## 23. Performance budgets (initial; adjustable via ADR with measurements)

| Metric | Budget |
|---|---|
| QR scan → paired (LAN) | ≤ 10 s |
| Reconnect after foregrounding (tailnet, p95) | ≤ 3 s |
| Agent tap → first structured event (p95, excluding agent's own model latency) | ≤ 5 s |
| Event latency Mac → iOS (LAN / tailnet, p95) | ≤ 500 ms / ≤ 1.5 s |
| Approval decision → applied on Mac (LAN / tailnet, p95) | ≤ 1 s / ≤ 2 s |
| Timeline scrolling with 10k events | 60 fps sustained |
| Terminal rendering under typical output | ≥ 30 fps; backpressure engages beyond 1 MB/s |
| Memory after 8 h session | < 250 MB growth |
| Attachment transfer (LAN) | ≥ 5 MB/s |
| Database growth | bounded by retention policy; vacuum verified in tests |

Every phase runs the profiling checks relevant to its scope (Output Contract, Phase Prompt Pack); full profiling in Phase 12. Measurement scaffolding (signposts, frame counters, XCTest metrics) is created in Phase 1 and wired into the transport in Phase 3, so budgets are checkable as the code lands — not only in Phase 12.

## 24. Testing strategy

- **Unit:** pairing token expiry, key rotation, message signatures, replay protection, protocol versioning, event decoding/ordering, resume cursors, permission matching, risk classification, canonical paths, symlink escape, redaction, agent state transitions, attachment validation.
- **Adapter:** deterministic fake executables for Codex JSON-RPC, Claude stream JSON, Claude hooks, ACP, PTY prompts, approval requests, malformed events, slow streams, large output, crashes. **The normal test suite never requires real provider accounts.**
- **Integration:** new pairing, re-pairing, revocation, Tailscale-style address, local network, Cloudflare-style proxied WebSocket, network drop, iPhone backgrounding, Mac sleep/wake, Mac logout/login, companion restart, agent restart, multiple simultaneous agents, large diff, large terminal history, clipboard image, app upgrade, protocol-version mismatch.
- **UI:** onboarding, agent launch, approval resolution, dangerous approval, interruption, reconnection, Dynamic Type, dark/light, Reduce Transparency, compact width, iPad split view, landscape, keyboard navigation.
- **Performance:** all §23 budgets.

## 25. Build and code quality rules

Use: structured concurrency; actors for mutable shared state; `@MainActor` for UI state; dependency injection; protocol-backed services; Codable versioned messages; explicit error types; OSLog with privacy annotations; small focused files; feature-level modules where justified.

Forbidden: global mutable singletons; `try!`; force unwraps; detached tasks without ownership; unbounded output buffers; blocking process reads; polling when events are available; parsing terminal escape sequences in business logic; networking inside views; provider-specific branching throughout UI; hard-coded paths, agent versions, or glass colors; overengineered microservices.

**Warnings are defects.** The project builds cleanly after every phase.

## 26. Dependency policy

Default: system frameworks only. A third-party dependency is allowed only if ALL hold: Swift Package Manager distribution; permissive license (MIT/BSD/Apache-2.0); maintained (commit within last 12 months); no transitive networking or analytics; pinned exact version; recorded in `DEPENDENCIES.md` with justification; ADR in `DECISIONS.md`.

- **Pre-approved** (these still require the `DEPENDENCIES.md` entry; the per-dependency ADR is waived): SwiftTerm (terminal engine, Phase 5 — do not implement a terminal emulator from scratch; wrap the engine behind an internal `TerminalEngine` protocol so it can be replaced without architectural change); Sparkle 2 (companion target only, §7); SwiftNIO (relay target only, §14.3).

## 27. CI and local build contract

- `scripts/build.sh` and `scripts/test.sh` must run headless via `xcodebuild` from a clean checkout.
- GitHub Actions workflow is optional in v1; if added, it runs the same two scripts on macOS runners.
- Every phase ends with both scripts green and zero warnings.

## 28. App Review strategy (produced in Phase 0)

Map the product against App Review Guidelines (notably 2.5.x executable code, 4.x design, 5.1.x privacy). The product's position: no code is downloaded to or executed on iOS; all agent execution is user-initiated and occurs on the user's own Mac. Deliverables: guideline mapping, demo account/flow for review, review notes draft, screen recording script showing pairing → task → approval → result. Risk items get mitigations recorded in `DECISIONS.md` before Phase 15.

---

## 29. Phased implementation plan

Rule: **one phase per run.** At the start of every phase: inspect the repository, document assumptions, list files that will change, implement the smallest complete vertical slice, build, test, fix warnings and concurrency violations, record results. A phase is never complete "because code was written" — only when its acceptance criteria pass. A phase may span multiple sessions when acceptance is not met — resume with carry-over context rather than forcing a false pass. Fixing defects from earlier phases is in scope only when they block this phase's acceptance criteria; log each such fix under Deviations. Opportunistic refactors of earlier phases remain out of scope.

Global per-phase structure: **Goal / Implement / Acceptance / Artifacts.**

### Phase 0 — Repository and feasibility audit
- **Goal:** establish ground truth before any product code.
- **Implement:** existing-project audit (if §1 is unfilled or the repo is greenfield, fill §1 from observed reality — greenfield is a valid finding; the build baseline is then "no build exists" plus recorded toolchain-detection results); target/dependency/entitlement inventory; security risks; proposed folder structure; architecture decision records (including the §12.5 storage-technology ADR); build baseline; re-verify every §3 assumption against current vendor docs (record source + date; if verification is impossible, mark the assumption UNVERIFIED with date and plan as if it were false); check "AgentDeck" name collisions (App Store, GitHub, product web) and record findings; draft threat model (§20.1); App Review strategy (§28).
- **Acceptance:** `ARCHITECTURE.md`, `SECURITY.md`, `BUILD_PROGRESS.md`, `DECISIONS.md`, `DEPENDENCIES.md` exist; assumption-verification table complete; clean build baseline recorded.
- **Artifacts:** the five documents above.

### Phase 1 — Shared foundations
- **Goal:** shared Swift package with the versioned protocol.
- **Implement:** core identifiers; agent event model; session state machine (§10.3); approval model; §9 wire protocol v1; serialization tests (including the §9 known-answer signature vectors); redaction utilities; logging abstraction; lightweight metrics/signpost scaffolding (§23); `scripts/build.sh` + `scripts/test.sh`.
- **Acceptance:** package builds for iOS and macOS; protocol tests pass; no provider-specific types leak into UI-facing modules; both scripts green.
- **Artifacts:** `Packages/Shared`, scripts.

### Phase 2 — Minimal macOS companion
- **Goal:** menu-bar shell with lifecycle and settings.
- **Implement:** menu-bar app; onboarding window; settings scene (§12.7); `SMAppService` start-at-login; companion status; local session database; Pause Remote Access; diagnostics export.
- **Acceptance:** no Dock presence after onboarding; login item toggles reliably; no admin access required.
- **Artifacts:** `Companion/` target.

### Phase 3 — Pairing and local transport
- **Goal:** two devices cryptographically paired and talking.
- **Implement:** device identity (§13.1); QR pairing (§13.2 parameters); TLS WebSocket (§9, §13.4); mutual authentication; device list; revocation; Bonjour onboarding; reconnect + event cursor.
- **Acceptance:** simulator/device pairs locally; revoked device cannot reconnect; replay tests fail safely; pairing completes within §23 budget.
- **Artifacts:** pairing + transport modules in Shared and both apps.

### Phase 4 — Project authorization and agent discovery
- **Goal:** user authorizes projects; companion finds installed agents.
- **Implement:** native folder picker; project profiles (display name, secure path reference, git root, branch, preferred agent/model, default permission profile, last session, last opened); recents/favorites/worktrees/non-git/remove/reauthorize; executable discovery (§12.3); version detection; launchpad data. Never scan the home directory without permission.
- **Acceptance:** configured test agents discovered; no unauthorized scanning; project removal invalidates access.
- **Artifacts:** registry + project modules.

### Phase 5 — Terminal foundation
- **Goal:** the honest fallback exists before any adapter depends on it.
- **Implement:** PTY creation and supervision hooks (§12.4 subset); SwiftTerm wrapped behind `TerminalEngine` protocol (§26); ANSI colors, full Unicode, cursor movement, scrollback, selection/copy/paste, resize, keyboard accessory with Control/Escape; read-only raw-output view wired into the session screen; reattachment. Interactive TUI input completed here, not deferred.
- **Acceptance:** common TUI and shell workflows operate; terminal is reachable from every session; engine swappable behind protocol; §23 terminal budget met.
- **Artifacts:** `TerminalEngine` module.

### Phase 6 — Codex vertical slice — **first complete product milestone**
- **Goal:** pair → project → Codex → task → structured events → approval.
- **Implement:** §3/A3 verification — specifically the approval-response and cancellation RPCs of the installed Codex version, not merely the existence of app-server; Codex app-server adapter (§11.1); thread creation; prompt send; streamed text; approval receive/resolve (interim scope: Deny / Allow once only, minimal UI designed for replacement in Phase 8); stop; resume; iOS native timeline consuming shared events.
- **Acceptance:** full user journey works end-to-end with structured events; uncertain parses visibly degrade to terminal (§10.4).
- **Artifacts:** Codex adapter, timeline UI v1.

### Phase 7 — Claude vertical slice
- **Goal:** second adapter with non-destructive hook management.
- **Implement:** §3/A4 verification; installation detection; stream adapter; hook manager (explicit approval, backup, non-destructive merge, removable); permission events (interim approval scope as in Phase 6: Deny / Allow once); session resume; PTY fallback; settings backup/restore.
- **Acceptance:** existing Claude settings survive install and removal; structured events and terminal fallback both work.
- **Artifacts:** Claude adapter, hook manager.

### Phase 8 — Approval policy engine
- **Goal:** §15 as a product surface.
- **Implement:** risk model; §15.1 scoped decisions; persistent + expiring rules; Face ID for critical; audit history; approval inbox.
- **Acceptance:** no unrestricted always-approve exists anywhere; critical actions cannot be approved from a notification; rule explanations match §15.5 style.
- **Artifacts:** policy engine, approvals UI.

### Phase 9 — Clipboard, attachments, diffs
- **Goal:** §16 complete.
- **Implement:** text clipboard; screenshot transfer; file attachment; temp-file lifecycle; changed-file list; unified diff; iPad side-by-side.
- **Acceptance:** filenames cannot produce shell injection (tested); temp attachments deleted by policy; large diffs responsive per §23.
- **Artifacts:** transfer + diff modules.

### Phase 10 — Background notifications and relay
- **Goal:** approvals and completions reach a backgrounded iPhone.
- **Implement:** APNs registration; `agentdeck-relay` per §14.3; redacted payloads; categories/actions; deep links; cursor-based reconnect.
- **Acceptance:** backgrounded device receives completion/approval alerts; relay verifiably never receives code or terminal output; `NEEDS-HUMAN` entries filed for APNs keys/hosting.
- **Artifacts:** `Relay/` service, notification modules.

### Phase 11 — Grok, Kimi, OpenCode, and shared ACP
- **Goal:** one ACP client, three adapters.
- **Implement:** §3/A5–A7 verification, including wire-format compatibility of each vendor's "ACP" (do not assume one client serves all); shared ACP client for compatible vendors, per-vendor protocol modules behind the shared `AgentAdapter` interface for incompatible ones (shared transport/event types are never forked); Grok, Kimi, OpenCode adapters; capability negotiation; approval mapping; PTY fallback; generic-agent adapter (§11.1 #6).
- **Acceptance:** ACP adapters reuse shared transport/event models; unsupported capabilities degrade visibly; generic agents default to terminal mode.
- **Artifacts:** ACP client + adapters.

### Phase 12 — Liquid Glass polish and accessibility
- **Goal:** §17 fully realized.
- **Implement:** system tab navigation; iPad split layout; native glass controls where justified; all §17 accessibility modes; light/dark; full §23 profiling pass.
- **Acceptance:** zero fake-glass implementations; navigation/controls use system rendering; content readable in every accessibility mode; §23 budgets met or ADR'd.
- **Artifacts:** UI polish, profiling report.

### Phase 13 — Widget and integration package
- **Goal:** §18 + §19.
- **Implement:** sanitized widget state; deep links; `AgentDeck` skill/hook package; reversible installer.
- **Acceptance:** removing the integration restores original files; widget performs no session supervision.
- **Artifacts:** widget extension, integration package.

### Phase 14 — Security hardening
- **Goal:** verify §20, don't assume it.
- **Implement:** threat-model review; dependency audit; secret-scanning audit; penetration-style protocol tests; path traversal/symlink tests; rate-limit tests; lost-device revocation test; notification privacy audit.
- **Acceptance:** zero unresolved critical findings; findings log with dispositions.
- **Artifacts:** `SECURITY.md` updated, findings report.

### Phase 15 — Distribution and onboarding
- **Goal:** ship.
- **Implement:** Developer ID signing; hardened runtime; notarization pipeline; stapled DMG; Sparkle 2 appcast (§7, §20.3); website download flow; iOS companion-install instructions; QR handoff; App Review notes (from §28); privacy policy; support diagnostics.
- **Acceptance:** clean-Mac install succeeds; Gatekeeper accepts; pairing succeeds with zero Terminal commands; App Review can reproduce the flow; update mechanism verified end-to-end.
- **Artifacts:** release pipeline, docs.

---

## 30. Global definition of done

A build is "done" only when all hold: clean checkout builds via `scripts/build.sh`; `scripts/test.sh` green; zero warnings; docs current (`ARCHITECTURE.md`, `SECURITY.md`, `BUILD_PROGRESS.md`, `DECISIONS.md`, `DEPENDENCIES.md`); the final deliverables listed below are present; no unresolved critical security findings; all `NEEDS-HUMAN` items listed in one place.

Final deliverables: working iOS/iPadOS app; macOS companion; shared protocol package; Codex, Claude, Grok, Kimi, OpenCode, and generic adapters; approval engine; secure pairing; Tailscale flow; Cloudflare documentation; clipboard/attachment transfer; diff viewer; terminal fallback; APNs relay; optional widget; security documentation; test suite; notarized DMG + Sparkle pipeline; App Store submission documentation; setup documentation. Plus: known limitations, deferred features, security assumptions, protocol compatibility table, agent capability matrix, release checklist, TestFlight checklist, Mac clean-install checklist.

## 31. Deferred features (do not build before core stability)

Full mobile code editor; remote desktop streaming; simulator video streaming; team collaboration; shared cloud workspaces; hosted agents; provider billing; agent marketplace; Tailscale Funnel exposure; built-in VPN; custom Network Extension; root daemon; Apple Watch approval app; full GitHub client; voice conversation mode; automatic deployment; automatic force-push approval; unrestricted global auto-approval; post-v1 approval choices UI (§15.2).

---

## 32. Documentation files the agent maintains

| File | Purpose |
|---|---|
| `ARCHITECTURE.md` | system design, toolchain pins, module map |
| `SECURITY.md` | threat model, protections, findings |
| `BUILD_PROGRESS.md` | per-phase log (template in phase prompt pack) |
| `DECISIONS.md` | ADRs + `NEEDS-HUMAN` entries |
| `DEPENDENCIES.md` | every third-party dependency + justification |
