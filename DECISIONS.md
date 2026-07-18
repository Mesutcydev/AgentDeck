# DECISIONS.md — ADRs, assumption verification, NEEDS-HUMAN

## §3 assumption verification (Phase 0, verified 2026-07-17)

| # | Claim | Result | Evidence | Source quality |
|---|---|---|---|---|
| A1 | iOS/iPadOS/macOS 26 current stable; Xcode 26.x production | **TRUE** | App Store requires 26-series SDK (Xcode 26+) since 2026-04-28 ([nerdschalk.com](https://nerdschalk.com/apples-new-app-store-sdk-requirements-must-do-by-april-2026/), [portalworks.de](https://portalworks.de/en/w/flutter-ios-26-die-kritische-migration-vor-april-2026)); iOS 27 announced as beta at WWDC 2026-06-08, so 26 is the shipping stable. Local: Xcode 26.5 (17F42), SDK 26.5 | secondary + local ground truth |
| A2 | Xcode 27 / iOS 27 are beta | **TRUE** | iOS 27 developer beta + Xcode 27 beta released 2026-06-08 ([ios27beta.com](https://ios27beta.com/ios-27-beta-release-timeline/), [aitoolsrecap.com](https://aitoolsrecap.com/Blog/apple-wwdc-2026-xcode-27-claude-gemini-foundation-models-developers), [macrumors.com](https://www.macrumors.com/guide/wwdc-2026-what-to-expect/)); final release expected Sept 2026 | secondary |
| A3 | Codex exposes app-server JSON-RPC suitable for structured integration | **TRUE, with caveat** | `codex app-server` = JSON-RPC 2.0 over stdio/JSONL with official schema tooling ([jaesolshin.com](https://jaesolshin.com/posts/codex-app-server-sdk/), 2026-05-20; [dmora/agentrun#49](https://github.com/dmora/agentrun/issues/49)). **Caveat:** approval-response RPC gap reported 2026-03-10 ([openai/codex#14192](https://github.com/openai/codex/issues/14192)) — SPEC §29 Phase 6 amended to verify the approval/cancel round-trip specifically. Codex binary not installed locally (only `~/.codex` config dir) | secondary |
| A4 | Claude Code supports stream JSON output and lifecycle/permission hooks | **TRUE** | Primary: [docs.anthropic.com hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks) (fetched 2026-07-17) — PreToolUse/PostToolUse/PermissionRequest/SessionStart etc., JSON stdin/stdout, `permissionDecision` allow/deny/ask. Local: `claude 2.1.210 --help` confirms `--output-format=stream-json` | primary + local ground truth |
| A5 | Grok CLI ("Grok Build") supports ACP over stdio | **PARTIAL — name TRUE, wire format UNVERIFIED** | Product name "Grok Build" confirmed (xAI, beta 2026-05-14; [oflight.co.jp](https://www.oflight.co.jp/en/columns/grok-build-xai-cli-coding-agent-2026-06), [truefoundry.com](https://www.truefoundry.com/docs/ai-gateway/grok-build)). ACP supported via `grok agent stdio` per third-party runtime docs ([anet.vansin.me](https://anet.vansin.me/guide/runtimes)). **But** ACP lineage is ambiguous: one source describes xAI's own spec at github.com/xai-dev/acp ([dev.to](https://dev.to/akaranjkar08/xai-launched-grok-build-a-terminal-coding-agent-to-fight-claude-code-and-codex-5hg5)) vs the Zed-lineage ACP used by OpenCode/Kimi. Local `grok 0.2.99 --help` shows headless json/streaming-json but no ACP in root help. → ADR-0005; Phase 11 re-verifies against the installed CLI | secondary + local (inconclusive) |
| A6 | Kimi Code CLI supports ACP or documented machine-readable interface | **TRUE** | Local ground truth: `kimi 0.26.0 --help` lists `acp` — "Run kimi-code as an Agent Client Protocol (ACP) server over stdio." Secondary corroboration: [oh-my-kimi](https://github.com/ekhodzitsky/oh-my-kimi) migration notes ("kimi-code … ACP-based") | local ground truth + secondary |
| A7 | OpenCode exposes ACP or documented machine-readable interface | **TRUE** | Primary: [opencode.ai/docs/acp](https://opencode.ai/docs/acp/) (fetched 2026-07-17) — `opencode acp` starts JSON-RPC-over-stdio ACP server. Local: `opencode 1.17.7 acp --help` confirms | primary + local ground truth |
| A8 | Tailscale Funnel exposes services publicly (unsuitable as default) | **TRUE** | Funnel = public-internet exposure, no auth; serve = tailnet-only ([mintlify serve-vs-funnel](https://mintlify.com/tailscale-dev/ScaleTail/configuration/serve-vs-funnel), [docs.openprx.dev](https://docs.openprx.dev/fr/prx/tunnel/tailscale)). Spec prohibition stands | secondary (vendor-consistent) |
| A9 | Mac App Store sandbox incompatible with launching/supervising external agent executables | **TRUE** | Sandboxed apps cannot spawn arbitrary external executables: `spawn EPERM` under MAS sandbox ([electron#40050](https://github.com/electron/electron/issues/40050)); child processes inherit the sandbox profile, which agent CLIs requiring full user file/network access cannot tolerate ([openjdk thread](https://macosx-port-dev.openjdk.java.narkive.com/9PS2eSAg/spawning-a-new-process-from-a-sandboxed-app)). §7 direct-distribution decision stands | secondary (well-established platform behavior) |
| A10 | APNs requires a developer-operated relay; no permanent background WebSocket on iOS | **TRUE** | APNs requires an authenticated provider connection — `.p8` JWT over HTTP/2 from a developer-operated server ([OneSignal docs](https://documentation.onesignal.com/docs/en/ios-p8-token-based-connection-to-apns), [jcode IOS_CLIENT.md](https://github.com/1jehuang/jcode/blob/master/docs/IOS_CLIENT.md)); iOS background execution model prohibits permanent sockets (platform constraint). §14.3 relay stands | secondary + platform knowledge |

No assumption required an ADR amending a design section; A3's caveat and A5's partial result amended the affected *phase scopes* (already reflected in SPEC v2.1 §29).

---

## ADRs

### ADR-0001 — Greenfield repository baseline
- **Context:** SPEC §1 was unfilled; no existing project anywhere on the machine (verified via `mdfind` + directory survey).
- **Options:** (a) treat missing baseline as blocker; (b) greenfield baseline with toolchain detection as ground truth.
- **Decision:** Greenfield. Baseline = "no build exists" + recorded toolchain detection (Xcode 26.5/17F42, Swift 6.3.2, SDK 26.5, host macOS 27.0 beta). SPEC §1 filled accordingly.
- **Consequences:** Phase 1 creates the Xcode project and `Packages/Shared` from scratch under the pinned toolchain.
- **Reversible?** N/A — starting state.

### ADR-0002 — Session database: SQLite via system SQLite3, behind a repository protocol
- **Context:** §12.5 offered "SwiftData or SQLite". Requirements: 10k-event timelines at 60 fps (§23), explicit vacuum verification (§23 — vacuum is an SQLite concept), versioned migrations, zero third-party deps (§26), testability.
- **Options:** (a) SwiftData — modern but opaque concurrency/perf behavior under heavy write streams, migration control limited, vacuum N/A; (b) GRDB — excellent but third-party (would need full §26 review); (c) system SQLite3 C API behind a protocol.
- **Decision:** (c). Repository protocol in `Packages/Shared`; companion owns the single writer actor.
- **Consequences:** More manual SQL, but full control over concurrency, batching, vacuum, and migrations; satisfies §26 with no dependency.
- **Reversible?** Yes — behind the repository abstraction; SwiftData could replace it without touching call sites.

### ADR-0003 — Repository layout and module map
- **Context:** Greenfield; §2 references `Packages/Shared/Sources/Shared/ProductNaming.swift` (path unified in SPEC v2.1).
- **Options:** (a) single Xcode project with all targets + local SwiftPM package; (b) workspace with multiple projects; (c) XcodeGen/Tuist-generated.
- **Decision:** (a) — one `AgentDeck.xcodeproj` at root, local `Packages/Shared`, targets App/Companion/Relay/WidgetExtension; no project-generator dependency (§26). Layout per ARCHITECTURE.md §3.
- **Consequences:** Simple headless `xcodebuild` invocations for scripts/build.sh + test.sh (§27).
- **Reversible?** Yes — restructure later via ADR if targets outgrow one project.

### ADR-0004 — Goal-mode continuous execution (process deviation from PHASE_PROMPTS.md §How-to-use #4)
- **Context:** The pack prescribes human review+merge between phases. The user explicitly directed autonomous continuous operation (goal mode, 2026-07-17) with merge-to-main after each accepted phase.
- **Options:** (a) pause per phase for review; (b) merge accepted phases to main autonomously, branch next from main.
- **Decision:** (b), as directed. The deviation is recorded here per the pack's own escape clause. The independent-review prompt (PHASE_PROMPTS.md, milestone phases) remains available to the user at any time.
- **Consequences:** Main advances without per-phase human review; quality gates are the acceptance criteria, raw evidence in BUILD_PROGRESS.md, and green build/test scripts.
- **Reversible?** Yes — user can halt goal mode and resume the per-phase review gate at any phase boundary.

### ADR-0005 — ACP dual-lineage risk handling (Grok vs Zed-lineage ACP)
- **Context:** A5 verification: Grok Build supports "ACP", but sources disagree on whether it is xAI's own spec or the Zed-lineage Agent Client Protocol that OpenCode (`opencode acp`) and Kimi (`kimi acp`) implement. One shared ACP client may not serve all three.
- **Options:** (a) assume one client, discover at runtime; (b) verify wire compatibility per vendor first; per-vendor protocol modules where incompatible.
- **Decision:** (b), already amended into SPEC v2.1 §29 Phase 11. Shared transport/event types are never forked; divergence is isolated behind the `AgentAdapter` interface.
- **Consequences:** Phase 11 may produce 1–3 protocol modules; approval mapping and event model stay shared.
- **Reversible?** Yes — modules can converge if vendors align.

### ADR-0006 — AgentDeck.xcodeproj timing: created in Phase 2, not Phase 1
- **Context:** ARCHITECTURE.md §3 and ADR-0001's consequences note said Phase 1 creates `AgentDeck.xcodeproj`. SPEC §29 Phase 1 scope is only `Packages/Shared` + scripts; the first app target exists in Phase 2 (companion shell). An `.xcodeproj` with no app targets adds nothing and the Phase 1 executor was instructed not to create app targets.
- **Options:** (a) create an empty project in Phase 1; (b) build the SwiftPM package directly (SwiftPM for macOS, `xcodebuild -scheme Shared` auto-generating a project for iOS) and create the real `.xcodeproj` with the first app target in Phase 2.
- **Decision:** (b). ARCHITECTURE.md §3 corrected. The §27 headless contract is fully met: `scripts/build.sh` builds macOS via `swift build` and iOS via `xcodebuild -scheme Shared -destination 'generic/platform=iOS'` from `Packages/Shared` — verified green, zero warnings.
- **Consequences:** Phase 2 owns project creation (documented there); Phase 1 has no project-level settings to maintain (deployment targets and strict concurrency live in `Package.swift` and the scripts).
- **Reversible?** Yes — Phase 2 creates the project; no Phase 1 artifact depends on its absence.

### ADR-0007 — Wire v1 encoding choices and known-answer-vector methodology
- **Context:** SPEC §9 mandates: Ed25519 signature over the RFC 8785 (JCS) canonical encoding of the frame with `sig` absent; all frame numbers integers; fixed known-answer vectors pinning canonical bytes → expected signature. Two encoding decisions and one platform finding needed recording.
- **Findings (verified 2026-07-17):** (1) CryptoKit Ed25519 signing is **hedged** — `Curve25519.Signing.PrivateKey.signature(for:)` returns a *different* valid RFC 8032 signature per call for identical key+message (side-channel countermeasure); verification is plain RFC 8032 and accepts deterministic signatures from other implementations (cross-checked against libsodium via PyNaCl: same public key from the same seed, CryptoKit verifies the libsodium signature). (2) A deterministic per-run signature therefore cannot be reproduced by the platform signer.
- **Options:** (a) implement deterministic RFC 8032 signing by hand — rejected, never roll own crypto (§20, security > features); (b) pin canonical bytes + a fixed signature that must *verify*, with the sign path covered by sign→verify round-trip tests; (c) skip KATs — violates SPEC §9.
- **Decision:** (b). The two KAT vectors hardcode: fixed 32-byte seed (test-only), fixed frame, expected canonical bytes (exact string + byte count), and a fixed RFC 8032 signature produced by libsodium. The test asserts canonical bytes match exactly AND the hardcoded signature verifies over them — any canonicalization drift (key order, escaping, whitespace, integer forms) fails loudly on both platforms. Wire encoding choices inside §9's integer-only constraint: `EventConfidence` as integer basis points (10000/7000/4000/0); `Data` fields (nonce, sig) as base64 strings; UUIDs lowercase; `UInt64` counters must fit Int64 range (encode throws rather than clamps — 2^63 frames per direction is unreachable); `cursor` key omitted when absent; the wire encoding IS the JCS canonical encoding.
- **Consequences:** Signatures on the wire are valid RFC 8032 Ed25519 and verify identically everywhere; KATs pin the canonical form as SPEC requires, adapted for the platform's hedged signer. If a deterministic signer is ever mandated, only the KAT assertions change — the wire format is unaffected.
- **Reversible?** Yes — assertion-methodology-only; the protocol itself is exactly §9.

### ADR-0008 — Pairing bootstrap defers frame signature verification until peer key is pinned
- **Context:** During the QR handshake the peer's Ed25519 identity key is carried inside unsigned (structure-only) frames before the §13.2 mutual confirmation completes. Requiring `sig` verification against a pinned key before pairing finishes is impossible — the key is not yet trusted.
- **Options:** (a) verify signatures during bootstrap anyway (requires out-of-band key material — redundant with attestation); (b) decode bootstrap frames with timestamp/replay/structure checks only, verify embedded keys + §13.4 attestation in the handshake layer, then pin the peer key and enforce full signature verification on all subsequent frames.
- **Decision:** (b). `PeerConnection` calls `FrameCodec.decodeUnverified` until `setPeerPublicKey`; `PairingEngine` verifies hello/accept/complete signatures against the keys embedded in those messages and checks TLS hash ↔ attestation binding.
- **Consequences:** A narrow bootstrap window exists where frame *structure* is trusted but `sig` is not yet checked against a pinned key; the window closes at `pairingComplete`. Post-pairing traffic is fully signed.
- **Reversible?** Yes — could tighten with dual signatures later via ADR; wire format unchanged.

### ADR-0010 — Schema migration v3 for project profiles
- **Context:** Phase 4 requires git metadata, favorites, preferred agent/model, permission profile, and last-session linkage on authorized projects (SPEC §29 Phase 4). The v1 `projects` table only stored display name, canonical path, and timestamps.
- **Options:** (a) new `project_profiles` table keyed by project id; (b) ALTER TABLE on `projects` with nullable new columns; (c) JSON blob column for extensibility.
- **Decision:** (b). Migration v3 (`project-profile-fields`) adds the required columns with sensible defaults (`is_favorite`/`is_worktree`/`is_git_repository` default 0; others nullable). `SessionRepository.updateProject` and `project(matchingCanonicalPath:)` expose the enriched model.
- **Consequences:** Single-table project model stays simple; future fields require another append-only migration. Existing rows gain NULL/0 defaults on upgrade.
- **Reversible?** Yes — columns can be ignored or migrated forward; no wire-protocol impact.

### ADR-0012 — §9 terminal stream frame types (terminal.output / terminal.input)
- **Context:** Phase 5 streams PTY bytes between the Mac companion and iOS client. §9 v1 already carries `session.event` for structured agent events; raw PTY bytes must not be parsed in business logic (§25) but still need a signed transport.
- **Options:** (a) embed PTY chunks in `session.event` `rawOutput` payloads; (b) add dedicated `terminal.output` / `terminal.input` frame types with base64 byte blobs; (c) binary side channel outside §9.
- **Decision:** (b). New v1 frame types with versioned payloads (`TerminalOutputPayload`, `TerminalInputPayload`, `payloadV: 1`). Bytes stay opaque; SwiftTerm rendering happens only in the App target.
- **Consequences:** §9 frame-type enum grows; relay still never sees terminal bodies in Phase 10 (only notification summaries). Chunking for >1 MiB deferred to later phases.
- **Reversible?** Yes — could fold into chunked `session.event` later without changing the PTY supervisor API.

### ADR-0013 — §10.1 AgentAdapter + Phase 6 session control frames
- **Context:** Phase 6 requires Codex app-server integration, Mac-side session orchestration, and iOS timeline UI. §10.1 defines `AgentAdapter`; §9 had no client→companion prompt/interrupt frames. A3 re-verification (2026-07-17): Codex `app-server` uses JSON-RPC 2.0 NDJSON on stdio with `initialize`, `thread/start`, `turn/start`, `approval/respond`, `turn/cancel`, `thread/resume`; approval/cancel RPCs present in fixture + public docs (openai/codex app-server); live Codex binary still absent (NEEDS-HUMAN #3).
- **Options:** (a) embed prompts in `session.event`; (b) add `session.prompt` / `session.interrupt` payloads; (c) reuse `terminal.input` for prompts.
- **Decision:** (b) + §10.1 `AgentAdapter` / `AgentSessionStream` in Shared; macOS `CodexAdapter` + `AgentSessionOrchestrator`; `ApprovalResolveRequest` wire payload; interim iOS approval UI (Deny / Allow once only).
- **Consequences:** `PairingServerEngine` broadcasts live `session.event` frames and handles prompt/resolve/interrupt; `AgentLaunchConfiguration` carries explicit `sessionID`; fixture `Fixtures/test-codex-app-server` for §24 adapter tests.
- **Reversible?** Yes — frame types are versioned; adapter protocol can gain methods without breaking stored events.

### ADR-0014 — Claude turn model and PreToolUse hook side-channel
- **Context:** Phase 7 requires a second adapter with non-destructive hook management. A4 re-verified 2026-07-17 (hooks + `stream-json` unchanged TRUE). Claude Code headless flow is turn-based: each user prompt spawns a process with `-p`; session continuity uses `--session-id` then `--resume`. Approvals are delivered via PreToolUse hooks (JSON stdin/stdout, `permissionDecision`).
- **Options:** (a) long-lived Claude process with streaming stdin; (b) one process per turn with hook file side-channel for approvals; (c) parse permission prompts from stderr/PTY only.
- **Decision:** (b) + (c) fallback. `ClaudeHookManager` installs a managed PreToolUse command only after explicit user approval; backs up and merges non-destructively; hook writes `request-*.json` / polls `response-*.json` under `AGENTDECK_CLAUDE_HOOK_DIR`. `ClaudeAdapter` maps `stream-json` lines to shared events; blocks on hook via fixture/process, not fabricated approvals. PTY fallback when structured mode unavailable.
- **Consequences:** Settings backup under `~/.claude/agentdeck/`; test fixture `Fixtures/test-claude`; stdout drained via `readabilityHandler` (blocking `availableData` poll deadlocks mid-turn). Interim approval scope remains Deny / Allow once (Phase 8 expands).
- **Reversible?** Yes — hook can be removed via `ClaudeHookManager.removeHooks()`; adapter remains behind `AgentAdapter`.

### ADR-0011 — macOS-only agent discovery and project authorization services
- **Context:** §12.3 discovery runs `/usr/bin`-style process inspection and reads `homeDirectoryForCurrentUser`; §12.4 authorization invokes `/usr/bin/git`. These APIs are unavailable or inappropriate on the iOS Shared build, which must still compile for the iPhone client.
- **Options:** (a) duplicate services in the Companion target only; (b) `#if os(macOS)` gate in Shared with catalog/types shared cross-platform; (c) stub no-op iOS implementations that always return empty.
- **Decision:** (b). `AgentCatalog`, `RegisteredAgent`, `LaunchpadData`, and `PathSafety` remain cross-platform; `AgentDiscoveryService` and `ProjectAuthorizationService` are macOS-only. The iPhone never performs executable discovery or folder authorization (Constitution #9).
- **Consequences:** iOS cannot call discovery/authorization APIs until a future ADR adds a remote RPC; Phase 4 acceptance is verified on macOS-hosted tests and Companion UI.
- **Reversible?** Yes — could add thin iOS stubs or RPC facades without changing the macOS implementations.

### ADR-0009 — Raw TLS/TCP length-prefix transport instead of WebSocket server
- **Context:** SPEC §13.4 describes TLS WebSocket. Network.framework's WebSocket *server* path rejected the self-signed P-256 identity during loopback integration tests; the client WebSocket path was not exercised because the server never came up cleanly.
- **Options:** (a) add a third-party WebSocket library (§26 ADR required); (b) keep Network.framework TLS but frame payloads with a 4-byte big-endian length prefix over raw TCP (same signed JSON bytes as §9); (c) custom WebSocket handshake implementation.
- **Decision:** (b). `PeerConnection` sends/receives length-prefixed blobs; TLS + pinned public-key hash binding unchanged; Bonjour advertisement remains on the listener for discovery-only (§13.5 mode 2).
- **Consequences:** Not byte-identical to a WebSocket wire capture, but the application payload (JCS-canonical signed JSON) is identical; simplifies server-side TLS on macOS without new dependencies.
- **Reversible?** Yes — could wrap the same codec in WebSocket frames later if a vetted server stack is added.

### ADR-0019 — Approval policy persistence uses explicit rules + audit tables
- **Context:** Phase 8 turns §15 into a product surface: scoped persistent rules, expiring/session rules, audit history, and secure confirmation for critical actions. Reusing the generic `events` table would blur user policy state with adapter timeline data and make revocation/query semantics awkward.
- **Options:** (a) encode rules/audit as `session.event` payloads only; (b) add `approval_rules` and `approval_audit_entries` tables plus repository APIs; (c) store policy state in an untyped JSON blob on projects.
- **Decision:** (b). Schema migration v4 adds dedicated tables: `approval_rules` (choice, project/session scope, optional command pattern, explanation, lifecycle timestamps) and `approval_audit_entries` (request/rule references, event kind, summary, redacted metadata, timestamp). `ApprovalPolicyEngine` owns matching, secure-confirmation enforcement, and audit writes.
- **Consequences:** Approval state becomes searchable, revocable, and testable independent of provider events; critical-approval policy can be enforced centrally on the companion even when UI surfaces evolve.
- **Reversible?** Yes — the policy engine sits behind `SessionRepository`; a future store or richer schema can migrate forward without touching app/UI call sites.

### ADR-0015 — Diff generation uses `/usr/bin/diff` with explicit temp-file staging
- **Context:** Phase 9 requires changed-file lists, unified diffs, and filename-injection tests. The initial plan used `git diff --no-index` with custom labels, but the installed Git build rejects `--label` in that mode, which would force absolute temp paths into the UI and tests.
- **Options:** (a) implement a line-diff algorithm from scratch; (b) shell out through `/bin/sh -c` to reshape Git output — rejected on security grounds; (c) call `/usr/bin/diff -u` directly via `Process`, synthesize the surrounding `diff --git` metadata, and keep all filenames as plain arguments.
- **Decision:** (c). `DirectoryDiffGenerator` gathers changed files, runs `/usr/bin/diff -u --label …` per file, rewrites add/delete headers where needed, and feeds the resulting unified diff into the strict `UnifiedDiffParser`.
- **Consequences:** The product gets stable relative-path diffs without shell interpolation, and hostile filenames remain inert because they are never parsed by a shell.
- **Reversible?** Yes — the UI consumes shared diff models, so a future generator (Git, libgit2, or a pure-Swift implementation) can replace the backend without changing app code.

### ADR-0017 — Shared ACP client for Kimi/OpenCode; Grok uses separate stream module
- **Context:** Phase 11 requires one shared ACP transport for compatible vendors while ADR-0005 documents Grok ACP wire ambiguity.
- **Decision:** `ACPClient` + `ACPAgentAdapter` serve Kimi (`kimi acp`) and OpenCode (`opencode acp`). `GrokAdapter` uses headless stream-json when available with PTY fallback — not the Zed-lineage ACP client.
- **Consequences:** Shared `AgentEvent` models are never forked; wire-incompatible vendors sit behind separate adapter modules.
- **Reversible?** Yes — new vendor modules plug into `AgentAdapter` without changing iOS UI types.

### ADR-0018 — §23 profiling budgets met headlessly; LAN GUI pass deferred
- **Context:** Phase 12 requires §23 profiling; physical LAN pairing GUI is NEEDS-HUMAN #10.
- **Decision:** Record headless build/test timings in `docs/PROFILING.md`; defer interactive LAN latency measurement.
- **Consequences:** CI proves build/test budgets; human pass still required before App Store submission.
- **Reversible?** Yes.

### ADR-0016 — Phase 10 notification relay uses simulated APNs and strict payload ceiling
- **Context:** Phase 10 requires background iPhone alerts via APNs and a developer-operated relay (§14.3). Apple Developer credentials and relay hosting are unavailable (NEEDS-HUMAN #2, #7).
- **Options:** (a) skip Phase 10 until credentials exist — rejected (SPEC §5.3: complete unblocked work, downgrade acceptance); (b) ship unrestricted relay payloads — rejected (§14.3 hard ceiling); (c) implement full schema + Ed25519 auth + simulated APNs outbox locally, file NEEDS-HUMAN for production `.p8` and hosting.
- **Decision:** (c). `RelayNotifyRequest` allows only §14.3 fields; `RelayNotifyValidator` rejects terminal output, source code, prompts, and credentials. The relay records deliveries in `SimulatedAPNsOutbox`; iOS registers opaque destination tokens via `device.pushToken`. Production APNs delivery awaits human credentials.
- **Consequences:** Automated tests prove signature verification and forbidden-field rejection; manual background-alert acceptance uses sandbox relay + simulated delivery until NEEDS-HUMAN items resolve.
- **Reversible?** Yes — swap `APNsDeliveryMode.simulated` for real APNs HTTP/2 client when `.p8` credentials exist; companion `RelayNotificationCoordinator` unchanged.

### ADR-0020 — Notification relay hosting: minimal SwiftNIO HTTP/1 service now; production requirements recorded
- **Context:** ADR-0016 left relay hosting open (NEEDS-HUMAN #7). The relay's job is narrow: accept Ed25519-signed §14.3 notify requests from paired Macs and forward them to APNs. (ADR numbering note: ADR-0017 was already allocated to the shared ACP client decision, so this hosting ADR takes 0020.)
- **Options:**
  - (a) **Minimal SwiftNIO HTTP/1 service (current).** ~150 lines of pipeline code, one dependency (SwiftNIO, already §26-approved for the relay), single static binary, trivially containerized. Carries no APNs provider client yet — delivery is simulated.
  - (b) **Vapor.** Full web framework: routing, middleware, async/await, mature APNs libraries (`apns`, `vapor-apns` wrapping APNSwift). Real benefits only appear when the relay needs multiple endpoints, auth flows, or structured APNs delivery; until then it imports a large framework surface (and transitive dependencies) for one POST route. §26 review cost non-trivial.
  - (c) **Serverless (Cloudflare Workers / AWS Lambda + API Gateway).** Zero standing infrastructure and cheap at this volume, but: request signing verification and APNs HTTP/2 provider connections must live in someone else's runtime (no Swift on Workers; Lambda Swift runtime adds cold starts); per-request APNs connection setup is hostile to APNs' keep-alive HTTP/2 provider model; token state (`.p8` JWT caching) fights the stateless model; ops moves to a cloud account the project does not have (NEEDS-HUMAN #5/#7).
- **APNs reality check:** production APNs requires a persistent HTTP/2 provider connection with token-based (.p8 JWT, hourly refresh) or certificate auth — a long-lived process, which both (a) and (b) provide naturally and (c) does not.
- **Decision:** (a) ships now. The §14.3 security properties live at the application layer (fixed schema, Ed25519 verification, replay cache, rate limits, body cap), not in the framework — Vapor would add none of them. Production requires, in order: NEEDS-HUMAN #2 (`.p8` key) → an APNs HTTP/2 provider client (APNSwift or equivalent, new §26 review) replacing `SimulatedAPNsOutbox`; TLS termination in front of the relay (the wire is plain HTTP/1 — non-negotiable before any non-loopback exposure); a hosting decision (NEEDS-HUMAN #7). If the endpoint count grows (device registration, feedback, health), re-evaluate (b) at that point.
- **Consequences:** Relay stays one small binary; hardening (2026-07-18: 64 KiB body cap, replay cache, per-IP rate limit, fail-fast key, loopback default bind) is framework-independent and carries forward to any future stack.
- **Reversible?** Yes — the HTTP surface is one POST route plus `/healthz`; porting to Vapor or a worker is a rewrite of `RelayCore` only, with `Shared` payload/signing types unchanged.

---

## NEEDS-HUMAN

### NEEDS-HUMAN #1 — Product name conflict ("AgentDeck")
- **Needed:** decision — keep or rename.
- **Finding (2026-07-17):** at least two shipping products in the *same category* use the name: [github.com/puritysb/AgentDeck](https://github.com/puritysb/AgentDeck) — physical controller & multi-surface dashboard for AI coding agents (Stream Deck+, Android, iOS/macOS), active 2026-06; [agentdeck.site](https://agentdeck.site/) — "Agent Deck", a native macOS cockpit for terminal agent sessions (2026-06).
- **Why human:** trademark/App-Store risk assessment and naming are product-owner calls. Rename cost is low by design (SPEC §2: `ProductNaming.swift` + target names) — but only while no public artifacts exist.
- **Needed by:** before Phase 15 (distribution); ideally before any public presence.

### NEEDS-HUMAN #2 — Apple Developer Program membership
- **Needed:** paid developer account access.
- **Consumed by:** APNs `.p8` key (Phase 10), Developer ID + notarization + TestFlight + App Store Connect (Phase 15), physical-device testing (any phase).
- **Blocks:** Phase 10 full acceptance (degradable to locally-run/simulated relay per §14.3), Phase 15, on-device testing.

### NEEDS-HUMAN #3 — Codex CLI installation
- **Needed:** install Codex CLI on the build machine (binary absent; `~/.codex` config dir exists). Vendor install command per current docs; global CLI installs are outside the agent's boundaries without consent.
- **Consumed by:** Phase 6 schema generation + manual verification. Automated adapter tests use fake executables regardless (§24), so the test suite never blocks on this.

### NEEDS-HUMAN #4 — Tailscale account / tailnet
- **Needed:** Tailscale installed and signed in on the Mac + one iOS device sharing a tailnet.
- **Consumed by:** Phase 3+ integration testing of connection mode 1 (§13.5), event-latency budget verification over tailnet (§23).

### NEEDS-HUMAN #5 — Cloudflare account
- **Needed:** account for Tunnel + Access (advanced connection mode 3, §13.5).
- **Consumed by:** Phase 3+/Phase 14 documentation and proxied-WebSocket integration test.

### NEEDS-HUMAN #6 — Website hosting + domain
- **Needed:** hosting decision for the companion download flow (Phase 15). Cost implication → human (§5.3).

### NEEDS-HUMAN #7 — Relay hosting
- **Needed:** hosting decision for `agentdeck-relay` (Phase 10 production path; Docker-ready artifact will exist regardless). Cost implication → human (§5.3).

### NEEDS-HUMAN #8 — Real provider accounts for manual end-to-end validation
- **Needed:** signed-in accounts for Codex/Claude/Grok/Kimi/OpenCode for human acceptance passes (optional per phase).
- **Note:** the automated suite never needs them (§24 — deterministic fake executables).

### NEEDS-HUMAN #9 — Phase 2 GUI acceptance pass
- **Needed:** launch `DerivedData/Build/Products/Debug/Companion.app` once interactively and confirm: (1) the one-time onboarding window appears with a Dock icon, and after "Get Started" the Dock icon disappears (accessory policy); (2) the menu-bar item shows the §12.6 contents and Pause Remote Access visibly changes the status line; (3) Settings renders all ten §12.7 panes; (4) Export Diagnostics writes a redacted JSON via the save panel.
- **Why human:** GUI behavior cannot be observed headlessly. Code/config evidence is in BUILD_PROGRESS.md (Phase 2) — activation-policy code, generated Info.plist (no LSUIElement), and the automated SMAppService round-trip.

### NEEDS-HUMAN #10 — Phase 3 physical pairing GUI pass
- **Needed:** one iPhone + one Mac on the same LAN; launch the built Companion + iOS App; scan the companion's QR code with the device camera (or paste payload as fallback); confirm pairing completes within §23's ≤ 10 s LAN budget; optionally verify Bonjour discovery when `serviceName` is enabled.
- **Why human:** loopback integration tests cover the protocol on macOS-hosted client+server; camera QR UX and real-network timing cannot be asserted headlessly.
- **Blocks:** nothing in Phase 4+; recorded for honest §29 Phase 3 acceptance on physical hardware.
