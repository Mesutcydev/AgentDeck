# ARCHITECTURE.md — system design and toolchain pins

**Phase 0 baseline, 2026-07-17.** Greenfield repository; this is the proposed architecture. Deviations go through ADR (DECISIONS.md).

## 1. Toolchain pin (normative)

| Item | Pin | Source |
|---|---|---|
| Production Xcode | **26.5 (17F42)** | `xcodebuild -version` on build machine, 2026-07-17 |
| Swift | **6.3.2** (swiftlang-6.3.2.1.108) | `swift --version`, 2026-07-17 |
| SDKs | macOS 26.5, iOS 26.5 | `xcrun --show-sdk-version`, 2026-07-17 |
| Deployment targets | iOS 26.0, iPadOS 26.0, macOS 26.0 | SPEC §6 |
| Concurrency | `SWIFT_STRICT_CONCURRENCY=complete` on all targets | SPEC §6 |
| Host OS (build machine) | macOS 27.0 (26A5353q, beta) — Xcode 26.5 verified working on it | `sw_vers`, 2026-07-17 |

Production never depends on beta-only APIs (SPEC §6). A `compat/xcode-27` branch tracks beta APIs and is created when first needed, not before. APIs introduced after OS 26 are gated behind availability checks.

## 2. Components (SPEC §8) and module map

```
┌─────────────────────────────────────────────────────────────┐
│ iOS/iPadOS app (App/)          Widget ext (WidgetExtension/) │
│  - SwiftUI, Liquid Glass        - sanitized state only        │
│  - binds ONLY to Shared models  - deep links only             │
└───────────────┬─────────────────────────────────────────────┘
                │ §9 wire protocol (signed frames, TLS+pinning,
                │  WebSocket, cursor resume)
┌───────────────▼─────────────────────────────────────────────┐
│ macOS companion (Companion/) — THE authenticated boundary     │
│  - menu-bar app, SMAppService login item                      │
│  - agent registry, process supervisor (PTY + structured io)   │
│  - session database (SQLite, ADR-0002), approval state        │
│  - adapters: Codex, Claude, Grok, Kimi, OpenCode, Generic     │
└───────────────┬─────────────────────────────────────────────┘
                │ pre-redacted, minimal payload
┌───────────────▼──────────────┐        ┌──────────────────────┐
│ Relay (Relay/) SwiftNIO      │───────▶│ APNs (.p8, NEEDS-    │
│  - POST /v1/notify only      │        │ HUMAN, Phase 10)     │
│  - Ed25519-authed, no logs   │        └──────────────────────┘
└──────────────────────────────┘

Packages/Shared (SwiftPM): identifiers, event model, session state
machine, approval model, §9 wire protocol, security primitives,
redaction, logging, metrics scaffolding. Used by App, Companion,
Relay (verify-only). The iOS UI never sees provider-specific JSON.
```

Dependency direction: `Shared ← App`, `Shared ← Companion`, `Shared ← Relay`. No target imports another target. Adapters live in the companion and implement `AgentAdapter` (SPEC §10.1) against Shared types only.

### Local terminal control plane

The Companion also owns a user-scoped Unix-domain socket at `~/Library/Application Support/AgentDeck/control.sock`. The bundled `agentdeck` executable uses the versioned `LocalControlProtocol` from Shared to launch provider processes under Companion PTY ownership, attach/detach terminal frontends, list session memory, and request safe provider-native imports. Socket mode `0600`, peer-UID verification, bounded newline-delimited messages, and replayed request-ID rejection make this a same-user control surface; it is never exposed to the network. External terminal PTYs are not seized. Import either resumes a verified provider session after its original process exits or offers a related new session.

## 3. Repository layout (ADR-0003)

```
AgentDeck/
├── SPEC.md  PHASE_PROMPTS.md  ARCHITECTURE.md  SECURITY.md
├── BUILD_PROGRESS.md  DECISIONS.md  DEPENDENCIES.md  APP_REVIEW.md
├── Packages/
│   └── Shared/                 # SwiftPM package (Phase 1)
│       └── Sources/Shared/     # incl. ProductNaming.swift (SPEC §2)
├── App/                        # iOS/iPadOS app target (Phase 3+ UI, Phase 6 timeline)
├── Companion/                  # macOS menu-bar app target (Phase 2)
│   └── Adapters/               # per-agent adapters (Phases 6, 7, 11)
├── Relay/                      # SwiftNIO service + Dockerfile + docker-compose.yml (Phase 10)
├── WidgetExtension/            # WidgetKit extension (Phase 13)
├── scripts/
│   ├── build.sh                # headless xcodebuild, clean-checkout capable (Phase 1)
│   └── test.sh                 # headless test runner (Phase 1)
└── Fixtures/                   # deterministic fake agent executables (Phase 1+, §24)
```

The Xcode project (`AgentDeck.xcodeproj`) is created in Phase 2 together with the first app target — plain project, no project-generator dependency (§26). Phase 1 needs no `.xcodeproj`: the Shared package is built directly by SwiftPM for macOS and by `xcodebuild -scheme Shared` (SwiftPM auto-generation) for iOS verification (ADR-0006).

## 4. Key architectural decisions

Recorded as ADRs in DECISIONS.md: greenfield baseline (0001), session database = SQLite via system SQLite3 behind a repository protocol (0002), repository layout (0003), goal-mode continuous execution with merge-to-main (0004), ACP dual-lineage handling (0005), xcodeproj timing (0006), v1 wire encoding and KAT methodology (0007).

## 5. Non-negotiable structural rules (from SPEC)

- Companion is the only authenticated boundary; iPhone never talks to agent protocols or providers (§4.9).
- Structured events carry §10.4 confidence; <0.7 renders "uncertain" and never populates approval cards.
- No fake Liquid Glass (§17); system rendering only.
- Session database is versioned with explicit migrations (§12.5); no raw secrets ever.
- Wire protocol §9 is normative; changes need ADR + version bump.
