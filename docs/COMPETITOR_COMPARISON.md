# AgentDeck competitive review

Updated July 19, 2026.

## Positioning

AgentDeck should not compete as another terminal emulator. Its strongest position is a provider-neutral, visual control plane for local coding agents: one native conversation surface for Claude Code, Codex, Grok, Kimi Code, and OpenCode, with provider identity, approvals, session memory, multiple Macs, and live terminal fidelity available when needed.

## Competitive map

| Product | Core strength | What AgentDeck already does differently | Gap AgentDeck should close |
|---|---|---|---|
| Happy | Native remote control for Claude Code and Codex, including steering, approvals, review, terminal continuation, and end-to-end encryption | Broader provider support and provider-specific visual terminals | Match its effortless encrypted internet relay, voice input, notifications, and review polish |
| Omnara | Parallel agents across desktop, web, mobile, and Watch; worktrees, diffs, voice, and optional cloud migration | Keeps the user's existing CLIs and Mac as the execution boundary | Add worktree orchestration, a reliable offline-host story, voice, and richer diff review |
| VibeTunnel | High-performance browser/mobile terminal forwarding, session recording, aliases, and mature Tailscale/ngrok access | Converts agent output into a chat/activity/decision model instead of exposing only a terminal | Add recordings/export, HTTPS Tailscale Serve automation, browser fallback, and deeper network diagnostics |
| Termius | Mature multi-platform SSH/SFTP, vaults, host organization, sync, collaboration, and enterprise controls | Purpose-built agent UX, one-tap provider launch, integrated approvals and session memory | Add search/tags, encrypted cloud sync, team roles, audit export, and enterprise identity controls |
| Blink Shell | Desktop-grade iOS terminal with SSH/Mosh, local tools, customization, and strong keyboard/external-display UX | More approachable, visual, and agent-aware than a raw terminal | Continue improving keyboard shortcuts, external display, terminal selection/copy, and accessibility |

## Highest-impact improvements

1. **Make remote reliability the first product promise.** Add a small connection state machine users can understand: Local, Tailnet, Relay, Reconnecting, Offline. Automate Tailscale Serve/HTTPS where possible and provide an encrypted relay fallback so 5G access does not depend on NAT behavior.
2. **Turn approvals into a review product.** Show the exact command, affected files, compact diff, risk level, working directory, provider, host, and remembered scope in one decision sheet. Add Face ID for destructive approvals and an exportable audit trail.
3. **Ship structured agent events.** Parse tool calls, edits, tests, plans, questions, and errors into native timeline objects while preserving a lossless raw console. This is the main visual differentiator from terminal apps.
4. **Add parallel worktree orchestration.** Let users start several providers against isolated worktrees, compare results, and merge or discard from iPhone.
5. **Build reliable session continuity.** Persist transcript, raw PTY chunks, activity events, diffs, approvals, provider metadata, host ownership, and resume commands. Add search and filters across sessions.
6. **Add voice and push as mobile primitives.** Voice should create editable prompts; push should deep-link directly to a blocked approval, question, completion, or failure.
7. **Strengthen multi-host UX.** Show latency, transport, Tailscale address, availability, running-agent count, and last-seen state in the host switcher. Never silently send a command to an ambiguous host.
8. **Build trust before monetization.** Keep onboarding, pairing, three successful launches, session viewing, approvals, stopping agents, restore, legal content, and diagnostics free. Gate the fourth new launch and premium orchestration. Show a launch meter after the first success; do not interrupt onboarding with a paywall.

## Implementation status in build 4

| Pillar | Shipped foundation | Next production increment |
|---|---|---|
| Remote reliability | Tailscale endpoint migration, reconnect backoff/circuit breaker, deterministic active-host routing, Local/Tailnet status | Tailscale Serve HTTPS automation and encrypted relay fallback |
| Structured event parsing | Native activity timeline for messages, commands, edits, tests, warnings, approvals, diffs, and lossless console | Provider adapter conformance fixtures and richer tool/result grouping |
| Decision review | Scoped approvals, remembered rules, audit trail, risk classification, exact session/host ownership | Face ID for critical actions and side-by-side multi-file diff review |
| Voice and push | APNs wiring and deep-link handling for sessions/approvals | Editable voice composer and production notification relay |
| Worktree orchestration | Worktree-aware project records, concurrent session engine, provider-specific launch | Native create/compare/merge/discard worktree workflow |

## Recommended pricing experiment

- Pro Monthly: test $12.99–$14.99.
- Pro Annual: test $89.99–$99.99, preselected only when the real App Store price makes the stated saving true.
- Do not invent countdowns or fake discounts. Optimize the value moment: present Pro only when a user attempts the fourth successful launch or a premium multi-host/worktree action.
- Track activation (paired + first successful prompt), second-session return, paywall view, purchase start, conversion, cancellation, remote connection success, and crash-free prompt sends.

## Sources

- [Happy product and security overview](https://happy.engineering/)
- [Happy feature documentation](https://happy.engineering/docs/features/)
- [Omnara product overview](https://remote.omnara.com/)
- [VibeTunnel project and architecture](https://github.com/amantus-ai/vibetunnel)
- [Termius features](https://termius.com/)
- [Termius plans and feature matrix](https://termius.com/pricing)
- [Blink Shell product overview](https://blink.sh/)
- [Blink Shell documentation](https://docs.blink.sh/)
