# APP_REVIEW.md — App Review strategy (SPEC §28)

**Draft, Phase 0, 2026-07-17.** Refined in Phase 15 with real build artifacts.

## 1. Product position (for the review notes)

AgentDeck is a remote control surface for AI coding agents that run **on the user's own Mac**. No code is downloaded to, interpreted, or executed on iOS. The iPhone/iPad app renders structured session state and collects user decisions; all agent execution is user-initiated and happens on the user's own computer, under the user's own accounts and permissions. Comparable App Store categories: SSH clients, remote-desktop apps, CI/CD monitors.

## 2. Guideline mapping

| Guideline | Concern | Position / mitigation |
|---|---|---|
| 2.5.2 (executable code) | Downloading/running code on iOS | Not applicable by design: iOS app executes no remote code; it exchanges signed JSON frames with the user's own companion app. Terminal rendering is display-only. |
| 2.5.x (private APIs) | Undocumented API use | System frameworks only (SPEC §26); SwiftTerm/Sparkle/SwiftNIO are the only third-party deps, all public-API. |
| 4.0 / 4.2 (design, minimum functionality) | "Wrapped website" / thin client rejection | Fully native SwiftUI, Liquid Glass per SPEC §17; iPad `NavigationSplitView`, keyboard navigation, Dynamic Type, Widget. Functionality is substantial without any account. |
| 5.1.1 (privacy) | Data collection, account requirement | Local-first (SPEC §21); no account required for core function; no analytics; privacy manifest + nutrition labels in Phase 15; optional relay documented with data lists (§14.3). |
| 5.1.2 (data use/sharing) | Third-party sharing | None. The relay (developer-operated) receives only pre-redacted notification text (§14.3). |
| 3.1.1 (IAP) | Payments | v1: no IAP, no subscriptions. Business model out of scope for review. |
| 2.3 (accurate metadata) | Screenshots/description accuracy | Final screenshots from the real pairing → task → approval flow (Phase 15). |

## 3. Demo account / flow for review

No account system exists, so no demo account is needed. Review environment:

- Reviewer Mac with the companion installed (notarized DMG) + review iPhone with the app.
- Pairing over the same local network (Bonjour) — no Tailscale/Cloudflare account required for review (§13.5 modes 2 first).
- A demo project folder with a **fake agent executable** (deterministic fixture from `Fixtures/`) so review never needs real AI-provider accounts (§24 philosophy). The fake agent walks through: task → streamed events → one safe approval → one high-risk approval (demonstrating Face ID + hold-to-confirm) → completion + diff.

## 4. Review notes draft

> AgentDeck controls AI coding agents (e.g. Claude Code, Codex) running on the user's own Mac. The iOS app executes no code; it displays session state and approvals from the user's Mac over an end-to-end authenticated connection (QR pairing, TLS pinning, signed messages). To review: install the companion from the provided DMG on any Mac, open the iOS app, scan the companion's QR code (both devices on the same network), open the included "Demo Project", tap the demo agent, and run the scripted task. The demo uses a local simulated agent — no AI provider account is needed. Approvals demonstrate our safety model: critical actions require Face ID and hold-to-confirm inside the app and can never be approved from a notification.

## 5. Screen recording script (Phase 15, ≤ 60 s)

1. (5 s) Mac: companion menu-bar icon → "Pair New Device" → QR with 120 s countdown.
2. (8 s) iPhone: scan QR → 6-word verification phrase shown on both screens → confirm.
3. (7 s) Select "Demo Project" → agent grid → tap agent → type task.
4. (15 s) Timeline streams structured events (reading → editing → running command).
5. (15 s) Approval card arrives → expand → risk badge + exact command → Face ID → hold-to-confirm.
6. (10 s) Completion card with diff summary → tap → unified diff → done. Caption: "Your Mac's AI agents, in your pocket."

## 6. Risk items and mitigations

| Risk | Mitigation |
|---|---|
| Reviewer conflates us with "AI chat wrapper" (4.x spam) | Demo shows the native control surface across real local runtimes; positioning text leads with control/approvals, not chat. |
| Reviewer demands provider accounts | Demo fake-agent path needs none; noted explicitly in review notes. |
| Network entitlements questioned (local network usage) | Accurate local-network usage description; Bonjour only for discovery (§13.5). |
| Name conflict ("AgentDeck" vs existing products, DECISIONS.md NEEDS-HUMAN #1) | Resolve before Phase 15 to avoid metadata/trademark rejection. |
