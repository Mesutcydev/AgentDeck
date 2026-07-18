# AGENT_CAPABILITY_MATRIX.md — adapter capabilities from code reality

Compiled 2026-07-18 from the adapter sources listed under **Evidence**. Rows
describe what the code implements and what fixture tests prove — not vendor
documentation. Anything not verified locally is marked **UNVERIFIED**.

Local CLI probe (2026-07-18, this wave): none of `codex`, `claude`, `grok`,
`kimi`, `opencode` resolved on `PATH`. Versions below are quoted from
DECISIONS.md §3 assumption verification (2026-07-17) and are marked
accordingly.

| Official name | Executable | Verified version | Structured interface | Approval interface | Session resume | PTY fallback | Authentication | Integration reliability class | Evidence (file refs) | Unknowns |
|---|---|---|---|---|---|---|---|---|---|---|
| Codex (OpenAI) | `codex` (`codex app-server`) | **UNVERIFIED** — binary not installed (NEEDS-HUMAN #3) | JSON-RPC 2.0 NDJSON over stdio (`initialize`, `thread/start`, `turn/start`) | `approval/respond` RPC (approval-RPC gap reported upstream, openai/codex#14192 — caveat in DECISIONS A3) | Yes — `thread/resume` (declared `sessionResume: true`) | Yes, via `PTYSupervisor` | Vendor CLI's own login (`~/.codex`) — **UNVERIFIED** locally | **Fixture-tested; live path UNVERIFIED** | `CodexAdapter.swift`, `CodexAppServerClient.swift`, `Fixtures/test-codex-app-server`, DECISIONS A3/ADR-0013 | Whether the installed CLI's approval/cancel round-trip works live; version; output schema drift |
| Claude Code (Anthropic) | `claude` | 2.1.210 recorded 2026-07-17 (A4); **not re-verified this wave** | `--output-format stream-json`, one process per turn (`-p`) | PreToolUse hook side-channel (`request-*.json`/`response-*.json`, `permissionDecision`), explicit opt-in install via `ClaudeHookManager` | Yes — `--session-id` then `--resume` | Yes, via `PTYSupervisor` | Vendor CLI's own login — **UNVERIFIED** locally | **Fixture-tested; version recorded locally once** | `ClaudeAdapter.swift`, `ClaudeHookManager.swift`, `Fixtures/test-claude`, DECISIONS A4/ADR-0014 | Live hook install on a real `~/.claude`; hook format stability across versions |
| Kimi Code (Moonshot) | `kimi acp` | 0.26.0 recorded 2026-07-17 (A6); **not re-verified this wave** | Zed-lineage ACP (JSON-RPC over stdio) via shared `ACPClient` | ACP permission requests mapped to approvals (declared `approvals: true`) | Yes — declared `sessionResume: true` | Via generic terminal mode if not launched via ACP profile | Vendor CLI's own login — **UNVERIFIED** locally | **Fixture-tested; version recorded locally once** | `ACPAgentAdapter.swift` (`ACPLaunchProfile.kimi`), `ACPClient.swift`, DECISIONS A6/ADR-0017 | ACP spec version drift; live session resume semantics |
| OpenCode (Anomaly) | `opencode acp` | 1.17.7 recorded 2026-07-17 (A7); **not re-verified this wave** | Zed-lineage ACP via shared `ACPClient` (same client as Kimi) | ACP permission requests mapped to approvals | Yes — declared | Via generic terminal mode | Vendor CLI's own login — **UNVERIFIED** locally | **Fixture-tested; version recorded locally once** | `ACPAgentAdapter.swift` (`ACPLaunchProfile.opencode`), `ACPClient.swift`, DECISIONS A7/ADR-0017 | Same ACP drift risk; behavioral differences vs Kimi on one shared client |
| Generic (user-defined) | user-configured path | N/A (user-supplied) | None — raw terminal only (declared `structuredEvents: false`) | None (declared `approvals: false`) | No | The adapter *is* the PTY path (`PTYSupervisor`) | Whatever the user's executable requires — outside AgentDeck | **Raw-only by design** | `GenericAgentAdapter.swift`, SPEC §11.1 #6 | Everything vendor-specific (intentionally out of scope) |
| Grok Build (xAI) | `grok` | 0.2.99 recorded 2026-07-17 (A5); **not re-verified this wave** | Headless stream-json attempted when available; **ACP wire lineage UNVERIFIED** (ADR-0005) — adapter does not use the Zed-lineage `ACPClient` | None (declared `approvals: false`) | No (declared `sessionResume: false`) | Yes — PTY fallback (`forcePTYFallback` seam) | Vendor CLI's own login — **UNVERIFIED** locally | **Partial — structured mode unverified, PTY fallback tested** | `GrokAdapter.swift`, DECISIONS A5/ADR-0005/ADR-0017 | Whether `grok agent stdio` speaks Zed-lineage ACP or xAI's own spec; approval surface; resume support |

## Reliability classes

- **Fixture-tested; live path UNVERIFIED** — deterministic fixture executables
  prove the adapter logic (§24); the real vendor binary has never been driven
  end-to-end on this machine.
- **Fixture-tested; version recorded locally once** — additionally, the CLI
  was present on 2026-07-17 and its `--help`/docs confirmed the interface.
- **Raw-only by design** — no structured contract exists; raw output is
  surfaced at `.ptyHeuristic` confidence (Constitution #2: never fabricate
  events).
- **Partial** — structured mode is implemented but its wire assumptions are
  unverified; the tested fallback is the PTY path.

## Method notes

- Capability flags are the adapters' own `AgentCapabilities` declarations
  (`structuredEvents`, `approvals`, `sessionResume`, `cancellation`,
  `streaming`) — declarations, not live proof.
- All adapters are macOS-only (`#if os(macOS)`); the iOS app never spawns
  agent executables (Constitution #9).
- No agent executable's code-signing identity is verified at launch yet —
  see THREAT_MODEL.md T15 (planned).
