# AgentDeck — Phase Prompt Pack

## How to use this pack

1. Place `SPEC.md` (the Master Specification) in the repository root. Fill in §1 (Context and repository) first — if you don't, Phase 0 fills it from observed reality.
2. Run **exactly one phase prompt per agent session.** Do not chain phases in one session. A phase may span multiple sessions when acceptance isn't met — that is normal; re-run with carry-over context (appendix), never force a pass.
3. Before each run, ensure these files exist in the repo: `ARCHITECTURE.md`, `SECURITY.md`, `BUILD_PROGRESS.md`, `DECISIONS.md`, `DEPENDENCIES.md` (created in Phase 0; before Phase 0 they do not exist yet — Phase 0 creates them).
4. Branching: each phase branches from the tip of the previous phase's branch — or from `main` after the previous phase is merged. The agent never merges or pushes its own branch; the human reviews the diff and merges. (If the human explicitly directs autonomous continuous operation — e.g., goal mode — the agent merges each accepted phase into `main`, branches the next phase from `main`, and records this deviation in `DECISIONS.md`.)
5. After each run: review the diff, review `BUILD_PROGRESS.md`, resolve any `NEEDS-HUMAN` entries you can, then start the next phase in a fresh session.
6. If a phase fails acceptance, re-run the same phase prompt with the failure notes appended under "Carry-over context."
7. After milestone phases (3, 6, 8, 10, 14), optionally run the independent-review prompt (bottom of this file) in a fresh session before starting the next phase.

---

## The Constitution (included verbatim in every prompt below)

```
CONSTITUTION — these rules outrank all other instructions:
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
```

## Output contract (included verbatim in every prompt below)

```
OUTPUT CONTRACT — required before you stop:
1. Work on branch `phase-N-<slug>`; conventional commits; keep the project buildable after every commit.
2. Update BUILD_PROGRESS.md using this template:
   ## Phase N — <name> — <date>
   - Status: complete | blocked | partial
   - Implemented: <bullet list>
   - Test evidence: <commands run, with raw output pasted — never summaries>
   - Acceptance criteria: <each criterion: pass/fail + executed evidence>
   - Deviations: <ADRs written, or "none">
   - Needs-human: <items, or "none">
3. Write ADRs in DECISIONS.md for any spec deviation, new dependency, or protocol decision (format: Context / Options / Decision / Consequences / Reversible?).
4. scripts/build.sh and scripts/test.sh must both pass with zero warnings.
5. Never weaken, delete, or skip a failing test to reach green; never mark an acceptance criterion "pass" without executed evidence. A criterion that cannot be met as written is marked failed and gets an ADR (SPEC §5.2).
6. Defects in earlier phases may be fixed only when they block this phase's acceptance; log each such fix under Deviations. No other changes to earlier phases' work.
7. When blocked by credentials, accounts, hosting, or contradiction: add a `## NEEDS-HUMAN` entry in DECISIONS.md describing exactly what is needed, then complete all unblocked work. Never guess credentials, never silently skip acceptance criteria.
8. Final response: summary of 20 lines or fewer — what was built, test results, open items.
```

---

## Phase prompt template (for creating additional prompts)

```
# AgentDeck — Phase N: <name>

CONSTITUTION — <paste verbatim>

## Context
Read these files before writing any code: SPEC.md §§<sections>, ARCHITECTURE.md,
DECISIONS.md (all entries), BUILD_PROGRESS.md (last entry).
Carry-over context: <none | notes from previous run>

## Goal
<one sentence from SPEC §29>

## Scope
Implement exactly the items listed under SPEC §29 Phase N "Implement".
Do not implement items belonging to later phases.

## Phase-specific constraints
<2–6 bullets unique to this phase>

## Acceptance criteria
<copied verbatim from SPEC §29 Phase N "Acceptance">

OUTPUT CONTRACT — <paste verbatim>
```

---

# Ready-to-run phase prompts

---

## Prompt — Phase 0: Repository and feasibility audit

```
# AgentDeck — Phase 0: Repository and feasibility audit

CONSTITUTION — these rules outrank all other instructions:
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

## Context
Read SPEC.md in full. Inspect the repository and reconcile it with SPEC §1.
This phase writes no product code.

## Goal
Establish ground truth before any product code (SPEC §29 Phase 0).

## Scope
- Audit existing project: targets, dependencies, entitlements, security risks.
- If SPEC §1 is unfilled or the repo is greenfield: fill §1 from observed reality. Greenfield is a valid finding — the build baseline is then "no build exists" plus recorded toolchain-detection results (xcodebuild/swift versions, SDKs).
- Propose folder structure and module map; record architecture decisions as ADRs.
- Establish the clean build baseline (record exact commands and results).
- Re-verify EVERY assumption in SPEC §3 (A1–A10) against current vendor documentation.
  For each: record claim, verified result, source URL, verification date in DECISIONS.md.
  Where an assumption is false, write an ADR amending the affected spec section before proceeding.
  If an assumption cannot be verified (no network/docs access), mark it UNVERIFIED with date and plan as if it were false — do not guess.
- Check "AgentDeck" name collisions (App Store, GitHub, product web); record findings in DECISIONS.md.
- Decide the session-database storage technology by ADR (SPEC §12.5).
- Draft the threat model (SPEC §20.1 list is the minimum).
- Produce the App Review strategy (SPEC §28): guideline mapping, demo flow, review-notes draft, recording script.

## Phase-specific constraints
- No product code. Documents and build scripts only.
- Verify product/protocol names from official sources (e.g., confirm whether "Grok Build" is the correct product name).
- Pin the production Xcode/Swift toolchain explicitly in ARCHITECTURE.md.

## Acceptance criteria (SPEC §29 Phase 0)
- ARCHITECTURE.md, SECURITY.md, BUILD_PROGRESS.md, DECISIONS.md, DEPENDENCIES.md exist.
- Assumption-verification table (A1–A10) complete with sources and dates.
- Clean build baseline recorded.

OUTPUT CONTRACT — required before you stop:
1. Work on branch `phase-0-audit`; conventional commits.
2. Update BUILD_PROGRESS.md per the standard template (phase, status, implemented, test evidence with raw command output, acceptance evidence, deviations, needs-human).
3. ADRs in DECISIONS.md for every false assumption and every architecture decision.
4. No code to build this phase; record the baseline instead.
5. Never mark an acceptance criterion "pass" without executed evidence; a criterion that cannot be met is marked failed with an ADR.
6. NEEDS-HUMAN entries for anything requiring credentials or accounts.
7. Final response: 20 lines or fewer.
```

---

## Prompt — Phase 1: Shared foundations

```
# AgentDeck — Phase 1: Shared foundations

CONSTITUTION — <paste the Constitution from the pack verbatim>

## Context
Read SPEC.md §§4–10, 24–27; ARCHITECTURE.md; DECISIONS.md (all); BUILD_PROGRESS.md (last entry).

## Goal
Shared Swift package with the versioned wire protocol (SPEC §29 Phase 1).

## Scope
Implement exactly SPEC §29 Phase 1 "Implement": core identifiers; agent event model; session state machine (§10.3); approval model; §9 wire protocol v1; serialization tests; redaction utilities; logging abstraction; scripts/build.sh + scripts/test.sh.

## Phase-specific constraints
- The §9 envelope is normative; any change requires an ADR and version bump.
- Confidence values per §10.4 are part of the event model from day one.
- Both scripts must run headless from a clean checkout (§27).

## Acceptance criteria (SPEC §29 Phase 1)
- Package builds for iOS and macOS.
- Protocol tests pass.
- No provider-specific types leak into UI-facing modules.
- Both scripts green, zero warnings.

OUTPUT CONTRACT — <paste the Output Contract from the pack verbatim, branch phase-1-foundations>
```

---

## Prompt — Phase 2: Minimal macOS companion

```
# AgentDeck — Phase 2: Minimal macOS companion

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§6, 12, 25, 27; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Menu-bar shell with lifecycle and settings (SPEC §29 Phase 2).

## Scope
Implement exactly SPEC §29 Phase 2 "Implement": menu-bar app; onboarding window; settings scene (§12.7); SMAppService start-at-login; companion status; local session database (§12.5); Pause Remote Access (§12.6); diagnostics export.

## Phase-specific constraints
- Accessory activation policy after onboarding; no permanent dashboard.
- No pairing/networking logic yet beyond internal seams — that is Phase 3.
- No admin access for any feature.

## Acceptance criteria (SPEC §29 Phase 2)
- No Dock presence after onboarding.
- Login item toggles reliably.
- No administrator access required.

OUTPUT CONTRACT — <paste verbatim, branch phase-2-companion-shell>
```

---

## Prompt — Phase 3: Pairing and local transport

```
# AgentDeck — Phase 3: Pairing and local transport

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§9, 13, 23, 24; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Two devices cryptographically paired and talking (SPEC §29 Phase 3).

## Scope
Implement exactly SPEC §29 Phase 3 "Implement": device identity (§13.1); QR pairing with §13.2 normative parameters (128-bit single-use nonce, 120-second expiry, exact payload field set); TLS WebSocket (§9, §13.4); mutual authentication; device list; revocation; Bonjour onboarding; reconnect + event cursor.

## Phase-specific constraints
- QR payload contains exactly the §13.2 fields — no reusable secrets.
- Replay, rate-limit, and timestamp-tolerance tests are part of done, not follow-ups.
- Multi-device semantics per §13.3.

## Acceptance criteria (SPEC §29 Phase 3)
- Simulator/device pairs locally within the §23 budget (≤ 10 s LAN).
- Revoked device cannot reconnect.
- Replay tests fail safely.

OUTPUT CONTRACT — <paste verbatim, branch phase-3-pairing>
```

---

## Prompt — Phase 4: Project authorization and agent discovery

```
# AgentDeck — Phase 4: Project authorization and agent discovery

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§12.3, 12.4, 16 (path-safety rules), 20; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
User authorizes projects; companion finds installed agents (SPEC §29 Phase 4).

## Scope
Implement exactly SPEC §29 Phase 4 "Implement": native folder picker; project profiles with the §29-listed fields; recents/favorites/worktrees/non-git/remove/reauthorize; executable discovery via §12.3 safe locations only; version detection; launchpad data.

## Phase-specific constraints
- Never scan the home directory without explicit permission.
- Detection runs only known inspection arguments; never execute shell-script output.
- Canonical-path and symlink-boundary checks apply to every stored project path.

## Acceptance criteria (SPEC §29 Phase 4)
- Configured test agents discovered.
- No unauthorized folder scanning occurs.
- Project removal invalidates access.

OUTPUT CONTRACT — <paste verbatim, branch phase-4-projects>
```

---

## Prompt — Phase 5: Terminal foundation

```
# AgentDeck — Phase 5: Terminal foundation

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§12.4, 23 (terminal budget), 26 (SwiftTerm pre-approval), 29 Phase 5; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
The honest fallback exists before any adapter depends on it (SPEC §29 Phase 5).

## Scope
Implement exactly SPEC §29 Phase 5 "Implement": PTY creation/supervision subset; SwiftTerm behind a `TerminalEngine` protocol; ANSI colors, full Unicode, cursor movement, scrollback, selection/copy/paste, resize, keyboard accessory with Control/Escape; read-only raw-output view in the session screen; reattachment; interactive TUI input.

## Phase-specific constraints
- Do NOT write a terminal emulator from scratch. Use SwiftTerm (write the §26 DEPENDENCIES.md entry).
- Every session screen must reach this terminal view — later phases depend on it.
- Terminal parsing stays out of business logic (§25).

## Acceptance criteria (SPEC §29 Phase 5)
- Common TUI and shell workflows operate correctly.
- Terminal reachable from every session; engine swappable behind protocol.
- §23 terminal budget met (≥ 30 fps typical; backpressure beyond 1 MB/s).

OUTPUT CONTRACT — <paste verbatim, branch phase-5-terminal>
```

---

## Prompt — Phase 6: Codex vertical slice (first product milestone)

```
# AgentDeck — Phase 6: Codex vertical slice

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§3 (A3), 10, 11.1 (#1), 22; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Pair → project → Codex → task → structured events → approval (SPEC §29 Phase 6).

## Scope
Implement exactly SPEC §29 Phase 6 "Implement": FIRST re-verify A3 against current Codex documentation and record source/date in DECISIONS.md (ADR if the interface differs) — specifically verify the approval-response and cancellation RPCs of the installed Codex version, not merely the existence of app-server; Codex app-server adapter; thread creation; prompt send; streamed text; approval receive/resolve; stop; resume; iOS native timeline consuming shared events.

## Phase-specific constraints
- The iPhone never connects to Codex directly; the companion translates (Constitution #9).
- Approval handling is interim scope: Deny / Allow once only, minimal UI designed for replacement — Phase 8 builds the real policy engine.
- Generate schemas from the locally installed Codex version when practical.
- Uncertain parses visibly degrade to the Phase 5 terminal (§10.4).
- Adapter tests use deterministic fake executables — no real provider account (§24).

## Acceptance criteria (SPEC §29 Phase 6)
- Full user journey works end-to-end with structured events.
- Uncertain parses visibly degrade to terminal.

OUTPUT CONTRACT — <paste verbatim, branch phase-6-codex>
```

---

## Prompt — Phase 7: Claude vertical slice

```
# AgentDeck — Phase 7: Claude vertical slice

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§3 (A4), 11.1 (#2), 19, 22; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Second adapter with non-destructive hook management (SPEC §29 Phase 7).

## Scope
Implement exactly SPEC §29 Phase 7 "Implement": FIRST re-verify A4 against current Claude Code documentation (record source/date; ADR if different); installation detection; stream adapter; hook manager; permission events; session resume; PTY fallback; settings backup/restore.

## Phase-specific constraints
- Hooks install only with explicit user approval; preview before install.
- Approval handling stays at interim scope (Deny / Allow once) — Phase 8 builds the policy engine.
- Back up existing Claude settings; merge non-destructively; never replace the file wholesale.
- Hooks removable from companion settings; removal restores original state.
- PTY mode only for workflows unavailable via stream mode — record each use.

## Acceptance criteria (SPEC §29 Phase 7)
- Existing Claude settings survive installation and removal.
- Structured events and terminal fallback both work.

OUTPUT CONTRACT — <paste verbatim, branch phase-7-claude>
```

---

## Prompt — Phase 8: Approval policy engine

```
# AgentDeck — Phase 8: Approval policy engine

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§10.4, 15, 14.2; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
SPEC §15 as a product surface (SPEC §29 Phase 8).

## Scope
Implement exactly SPEC §29 Phase 8 "Implement": risk model (§15.4); v1 scoped decisions (§15.1 only); persistent + expiring rules; Face ID for critical actions; audit history; approval inbox. Design the rule model to accommodate §15.2 later without migration.

## Phase-specific constraints
- No unrestricted always-approve control may exist anywhere — including debug UI.
- Critical actions require: expanded explanation, exact command, hold-to-confirm, Face ID, no notification-only approval, audit entry.
- Approval-relevant events below 0.7 confidence force the raw-terminal path (§10.4).
- Rule explanations follow §15.5 style; write unit tests for risk classification (§24).

## Acceptance criteria (SPEC §29 Phase 8)
- No unrestricted always-approve exists.
- Critical actions cannot be approved from a notification.

OUTPUT CONTRACT — <paste verbatim, branch phase-8-approvals>
```

---

## Prompt — Phase 9: Clipboard, attachments, diffs

```
# AgentDeck — Phase 9: Clipboard, attachments, diffs

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§16, 20, 23; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
SPEC §16 complete (SPEC §29 Phase 9).

## Scope
Implement exactly SPEC §29 Phase 9 "Implement": text clipboard; screenshot transfer; file attachment; temp-file lifecycle; changed-file list; unified diff; iPad side-by-side diff.

## Phase-specific constraints
- Attachment pipeline order is normative: encrypt → temp dir → validate → safe filename → agent gets path → retention deletion.
- Never interpolate attachment filenames into unescaped shell commands — write injection tests.
- No continuous clipboard sync by default; optional relay meets all §16.1 conditions.
- Not a mobile IDE.

## Acceptance criteria (SPEC §29 Phase 9)
- Filenames cannot produce shell injection (tested).
- Temporary attachments deleted by policy.
- Large diffs responsive per §23.

OUTPUT CONTRACT — <paste verbatim, branch phase-9-files-diffs>
```

---

## Prompt — Phase 10: Background notifications and relay

```
# AgentDeck — Phase 10: Background notifications and relay

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§14, 9, 21, 22; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Approvals and completions reach a backgrounded iPhone (SPEC §29 Phase 10).

## Scope
Implement exactly SPEC §29 Phase 10 "Implement": APNs registration; agentdeck-relay per §14.3 (single endpoint, Ed25519-authenticated, fixed minimal payload schema, ≤24 h retry queue, rate limits, no body logging); redacted payloads; categories/actions; deep links; cursor-based reconnect.

## Phase-specific constraints
- The relay's received-data list is a hard ceiling — build a test proving it never receives code or terminal output.
- High-risk approvals require opening the app; notification actions limited to §14.2.
- APNs .p8 key and hosting are NEEDS-HUMAN: file the entries, then make the phase pass with a locally-run or simulated relay, and record the limitation.

## Acceptance criteria (SPEC §29 Phase 10)
- Backgrounded device receives completion/approval alerts.
- Relay verifiably never receives code or terminal output.
- NEEDS-HUMAN entries filed for APNs keys/hosting.

OUTPUT CONTRACT — <paste verbatim, branch phase-10-notifications>
```

---

## Prompt — Phase 11: Grok, Kimi, OpenCode, and shared ACP

```
# AgentDeck — Phase 11: Grok, Kimi, OpenCode, and shared ACP

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§3 (A5–A7), 11.1 (#3–#6), 10; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
One ACP client, three adapters, plus the generic adapter (SPEC §29 Phase 11).

## Scope
Implement exactly SPEC §29 Phase 11 "Implement": FIRST re-verify A5, A6, A7 against current vendor documentation (record sources/dates; ADRs where different — including official product names) and verify the wire-format compatibility of each vendor's "ACP" against the local CLI installations — do not assume one client serves all; shared ACP client; Grok, Kimi, OpenCode adapters; capability negotiation; approval mapping; PTY fallback; generic-agent adapter (§11.1 #6).

## Phase-specific constraints
- ACP adapters must reuse shared transport and event models — no per-vendor forks of shared types.
- Where a vendor's ACP is wire-incompatible, build a per-vendor protocol module behind the shared `AgentAdapter` interface instead; shared transport/event types are never forked.
- Unsupported capabilities degrade visibly, never silently.
- Generic agents default to terminal mode; no brittle-regex destructive-prompt classification.

## Acceptance criteria (SPEC §29 Phase 11)
- ACP adapters reuse shared transport/event models.
- Unsupported capabilities degrade visibly.
- Generic agents default to terminal mode.

OUTPUT CONTRACT — <paste verbatim, branch phase-11-acp-adapters>
```

---

## Prompt — Phase 12: Liquid Glass polish and accessibility

```
# AgentDeck — Phase 12: Liquid Glass polish and accessibility

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§17, 23, 24 (UI/performance tests); ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
SPEC §17 fully realized (SPEC §29 Phase 12).

## Scope
Implement exactly SPEC §29 Phase 12 "Implement": system tab navigation (Home, Sessions, Approvals, Macs, Settings); iPad split layout; native glass controls only where justified; every §17 accessibility mode; light/dark; full §23 profiling pass.

## Phase-specific constraints
- Zero fake-glass implementations — remove any that slipped in earlier phases.
- Risk is never communicated by color alone.
- All strings via String Catalogs; no hard-coded user-facing strings.
- Profiling report is a required artifact; missed budgets need ADRs, not silence.

## Acceptance criteria (SPEC §29 Phase 12)
- No fake glass implementation exists.
- Navigation/controls use system rendering.
- Content readable in every accessibility mode.
- §23 budgets met or ADR'd.

OUTPUT CONTRACT — <paste verbatim, branch phase-12-polish>
```

---

## Prompt — Phase 13: Widget and integration package

```
# AgentDeck — Phase 13: Widget and integration package

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§18, 19; ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
SPEC §18 + §19 (SPEC §29 Phase 13).

## Scope
Implement exactly SPEC §29 Phase 13 "Implement": sanitized widget state via App Group; deep links; AgentDeck skill/hook integration package (Claude hook templates, Claude skill, Codex instruction template, Kimi skill, generic AGENTS.md guidance, event bridge helper); reversible installer.

## Phase-specific constraints
- Widget: no connections, no supervision, no terminal processing, no approvals, no secrets.
- Installer: explicit, previewable, reversible, non-destructive, versioned; test that removal restores original files byte-for-byte.

## Acceptance criteria (SPEC §29 Phase 13)
- Removing the integration restores original files.
- Widget performs no session supervision.

OUTPUT CONTRACT — <paste verbatim, branch phase-13-widget-integrations>
```

---

## Prompt — Phase 14: Security hardening

```
# AgentDeck — Phase 14: Security hardening

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§20, 13, 9, 15, 16; SECURITY.md (current); ARCHITECTURE.md; DECISIONS.md; BUILD_PROGRESS.md (last entry).

## Goal
Verify SPEC §20 — do not assume it (SPEC §29 Phase 14).

## Scope
Implement exactly SPEC §29 Phase 14 "Implement": threat-model review against §20.1; dependency audit (§26 compliance); secret-scanning audit; penetration-style protocol tests; path traversal and symlink tests; rate-limit tests; lost-device revocation test; notification privacy audit.

## Phase-specific constraints
- Every finding gets a disposition: fixed (with commit), accepted-risk (with ADR), or needs-human.
- Zero unresolved critical findings is a hard gate for Phase 15.
- Update SECURITY.md to reflect verified, not intended, protections.

## Acceptance criteria (SPEC §29 Phase 14)
- Zero unresolved critical findings.
- Findings log with dispositions.

OUTPUT CONTRACT — <paste verbatim, branch phase-14-hardening>
```

---

## Prompt — Phase 15: Distribution and onboarding

```
# AgentDeck — Phase 15: Distribution and onboarding

CONSTITUTION — <paste verbatim>

## Context
Read SPEC.md §§7, 20.3, 28, 30; ARCHITECTURE.md; DECISIONS.md; SECURITY.md; BUILD_PROGRESS.md (last entry).

## Goal
Ship (SPEC §29 Phase 15).

## Scope
Implement exactly SPEC §29 Phase 15 "Implement": Developer ID signing; hardened runtime; notarization pipeline; stapled DMG; Sparkle 2 appcast with EdDSA signing (§7, §20.3); website download flow; iOS companion-install instructions; QR handoff; App Review notes (from §28); privacy policy; support diagnostics.

## Phase-specific constraints
- Apple Developer credentials, App Store Connect access, and website hosting are NEEDS-HUMAN: file precise entries (what credential, where it goes, what command consumes it), then automate everything around them.
- Verify the Sparkle update path end-to-end with a test build.
- Run the Mac clean-install checklist on a fresh machine/VM if available; document gaps.

## Acceptance criteria (SPEC §29 Phase 15)
- Clean-Mac install succeeds; Gatekeeper accepts the companion.
- Pairing succeeds with zero Terminal commands.
- App Review can understand and reproduce the product flow.
- Update mechanism verified end-to-end.

OUTPUT CONTRACT — <paste verbatim, branch phase-15-distribution>
```

---

## Prompt — Independent review (run after milestone phases 3, 6, 8, 10, 14)

```
# AgentDeck — Independent review of Phase N

You did not write this code. You are the adversarial reviewer for Phase N, working in
a fresh session; distrust the previous session's claims until you reproduce them.

## Context
Read SPEC.md, DECISIONS.md, and the last entry of BUILD_PROGRESS.md. Check out the
phase branch under review (or main, if it was merged).

## Job
1. Re-run scripts/build.sh and scripts/test.sh from a clean state. Zero warnings required.
2. Verify every acceptance-criterion claim in BUILD_PROGRESS.md against the actual code
   and the raw test output. Flag any claim you cannot reproduce.
3. Check the diff against the Constitution (SPEC §4): fabricated events, fake glass,
   auto-approval surfaces, secrets handling, scope creep beyond Phase N.
4. Check DECISIONS.md ADRs against the code: was each ADR actually implemented as decided?

## Rules
- Read-only: make no code changes.
- Append findings to DECISIONS.md as a `## Review — Phase N — <date>` entry, each finding
  marked confirmed / discrepancy / constitution-violation, with evidence.
- Discrepancies and violations block the next phase until resolved.
```

---

## Appendix: carrying context between runs

If a phase must be re-run or was interrupted, append this block to that phase's prompt:

```
Carry-over context:
- Previous run status: <partial | blocked | failed acceptance>
- What exists: <branches/commits/artifacts>
- What failed: <acceptance criteria + evidence>
- Your job: resume from the existing state; do not restart completed, accepted work.
```
