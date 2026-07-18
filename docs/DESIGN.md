# AgentDeck iOS Design System

Version 2.0 — 2026-07-18
Status: normative for the iOS app (`App/`). Values here are the single
source of truth; views reference tokens, never raw numbers.

---

## 1. Principles

1. **Native glass, never fake glass.** The app targets iOS 26 minimum, so
   translucency comes from `TabView`'s system tab bar, `.glassEffect()`,
   `.buttonStyle(.glass)`, and `GlassEffectContainer`. No custom blur
   stacks, no `UIVisualEffectView` clones, no opacity-painted "frosted"
   rectangles. Where the system provides material behavior (tab bar,
   sheets, toolbars), we use it untouched.
2. **Measured, not random.** Every inset, radius, and font size comes
   from the token tables below. A new value enters the codebase only by
   entering this document first.
3. **Readable first.** Body text is never below 13 pt; primary content
   uses Dynamic Type text styles so the whole app scales. Terminal text
   is fixed at 13 pt SF Mono (its own accessibility setting aside).
4. **Honest chrome.** Agent terminal wrappers borrow each agent's own
   product personality (color, glow, rhythm) without pretending to *be*
   that product. The AgentDeck header stays visible so context is never
   ambiguous.
5. **Motion explains.** Animations show cause and effect (a sent prompt
   leaving the composer, an approval resolving). Nothing animates for
   decoration alone, and everything respects Reduce Motion.
6. **Conversation is the product.** Activity is a provider-aware chat,
   not a decorated terminal log. User prompts, streamed agent responses,
   tool events, changes, and approvals share one chronological surface.
   Console and raw output remain one tap away for expert inspection.

### 1.1 Brand signature

- **Deck mark:** three offset rounded layers plus a signal dot. It appears
  in app identity, the composer tools button, live conversation chrome,
  and intentional empty states—never as decorative wallpaper text.
- **Ownable palette:** ink, ultraviolet, and signal-lime define AgentDeck.
  Provider colors identify the active channel but never replace the shell.
- **Surface grammar:** opaque adaptive cards, a 3 pt semantic signal rail,
  one quiet border, and a shallow five-point shadow. No anonymous gray boxes.
- **Typography:** rounded heavy display/section faces, system body text, and
  monospace only for exact commands, diffs, fingerprints, and console output.
- **Motion:** slow ambient canvas drift, live-signal breathing, and streaming
  dots keep active pages alive. Reduce Motion freezes all ambient animation.

## 2. Tokens

### 2.1 Spacing — 4 pt grid

| Token      | Value | Use |
|------------|-------|-----|
| `space2xs` | 4     | Icon↔label gaps inside chips and badges |
| `spaceXs`  | 8     | Intra-card vertical rhythm, compact rows |
| `spaceS`   | 12    | Card internal padding (compact) |
| `spaceM`   | 16    | Screen margins, card padding (default) |
| `spaceL`   | 20    | Section spacing, sheet padding |
| `spaceXl`  | 24    | Hero padding, major section breaks |
| `space2xl` | 32    | Empty-state padding, sheet hero blocks |

Screen content margins: **16 pt** horizontal on iPhone, max readable
width **680 pt** centered on iPad.

### 2.2 Corner radii (continuous)

| Token        | Value | Use |
|--------------|-------|-----|
| `radiusChip` | 10    | Chips, badges, small buttons |
| `radiusCard` | 14    | Standard cards (agent cards, session rows) |
| `radiusHero` | 20    | Hero cards, approval cards, sheets' inner blocks |
| `radiusSheet`| 28    | Large containers, terminal surface corners |

Rule: nested radii differ by exactly one step (outer 20 → inner 14 →
chip 10). Never place radius-10 content directly inside radius-28.

### 2.3 Type scale

| Token        | Size/Style | Use |
|--------------|-----------|-----|
| `display`    | 34 bold (`.largeTitle`) | Home greeting, empty states |
| `title`      | 28 bold (`.title`) | Sheet titles |
| `headline`   | 22 semibold (`.title2`) | Section headers |
| `subhead`    | 20 semibold (`.title3`) | Card titles |
| `body`       | 17 (`.body`) | Primary content |
| `callout`    | 16 (`.callout`) | Secondary content |
| `caption`    | 15 (`.subheadline`) | Metadata, timestamps |
| `footnote`   | 13 (`.footnote`) | Legal, hints, terminal-status text |
| `mono`       | 13 SF Mono | Code, diffs, commands, terminal |
| `monoSmall`  | 12 SF Mono | Dense code (diff hunks, fingerprints) |

Minimums: interactive labels ≥ 15 pt; anything smaller is read-only.

### 2.4 Hit targets

- Minimum tap area **44 × 44 pt** everywhere (HIG). Icon-only buttons
  are drawn 17–20 pt and padded to 44.
- Primary action buttons: height **50 pt**, full-width in sheets.
- Segmented pickers: height **32 pt**.
- Tab bar: system-managed (native). No custom height.

### 2.5 Color

Base palette is semantic (`.primary`, `.secondary`, `.tint`,
`Color(.systemBackground)`) so light/dark both stay correct. Accent
palette:

| Token          | Light | Dark | Use |
|----------------|-------|------|-----|
| `deckInk`      | #191725 | #F4F1FF | Primary branded text |
| `deckCanvas`   | #F5F3FA | #0D0C13 | App-wide ambient canvas |
| `deckSurface`  | #FFFFFF | #191722 | Cards and conversation bubbles |
| `deckAccent`   | #6558E8 | #8B80FF | App shell, tabs, user messages |
| `deckSignal`   | #65A30D | #C6F36B | Live/presence signal only |
| `deckSuccess`  | #248A3D | #30D158 | Allow/approve, connected |
| `deckWarning`  | #FF9F0A | #FFD60A | Warnings, medium risk |
| `deckDanger`   | #D70015 | #FF453A | Deny, critical risk, errors |
| `deckInfo`     | #007AFF | #0A84FF | Informational |

Risk colors map: informational → info, low → success, medium → warning,
high → warning, critical → danger, unknown → secondary. Risk is never
color-only: every badge pairs color with its SF Symbol (§15 rule, kept).

## 3. Agent themes

Each agent has: an accent color, a terminal surface (background,
text tint, header tint), a glyph (SF Symbol), and a personality word
used in empty states. Applied anywhere the session's agent is known:
session rows, session header, terminal chrome, timeline accents.

| Agent | Accent | Terminal bg | Terminal text | Glyph | Personality |
|-------|--------|-------------|---------------|-------|-------------|
| Claude Code | #D97757 (coral) | #171310 warm black | #F5EDE6 warm white | coral starburst | "Thoughtful" |
| Codex | #10A37F (OpenAI green) | #0D1117 graphite | #E6EDF3 cool white | `chevron.left.forwardslash.chevron.right` | "Precise" |
| Kimi Code | #4C8DFF (Moonshot blue) | #0B1020 deep navy | #DCE6FF ice blue | `moon.stars.fill` | "Calm" |
| Grok | adaptive black/white (mono) | #000000 true black | #FAFAFA | mono disc + bolt | "Direct" |
| OpenCode | #2ED3B7 (teal) | #0A1414 | #D9F5F0 | `curlybraces` | "Open" |
| Generic / unknown | `deckAccent` | #101014 neutral | #EDEDF2 | `terminal.fill` | "Ready" |

Rules:
- Terminal background is **not** pure-tinted: 4–8 % hue mixed into a
  near-black so OLED contrast stays high and text passes WCAG AA (all
  pairs above ≥ 7:1 at 13 pt).
- The agent accent appears in exactly three places per screen: the
  header chip, the active-state indicator, and one primary control.
  More than that reads as a theme park, not a tool.
- Shell PTY sessions (`com.agentdeck.shell`) use the Generic theme.
- Provider marks are deliberately structural: Claude starburst, Codex
  code-ring, Kimi moon/stars, Grok mono disc/bolt, OpenCode braces. The mark,
  accent rail, terminal palette, and faint watermark travel together.

## 4. Glass policy

- Tab bar: system `TabView` (native Liquid Glass automatically),
  `.tabBarMinimizeBehavior(.onScrollDown)` so content wins on scroll.
- Floating elements (composer, terminal header overlay, approval card
  on timeline): `.glassEffect(.regular, in: .rect(cornerRadius:))`
  inside a `GlassEffectContainer` when siblings merge.
- Buttons in glass containers: `.buttonStyle(.glass)`; primary:
  `.buttonStyle(.glassProminent)` tinted with the agent accent.
- Sheets (New Session, pairing confirmation): system presentation
  detents and materials; inner content blocks use tokens, not glass.
- **Never** stack `.glassEffect` over another glass surface — one glass
  layer per z-plane.

## 5. Motion

| Token | Spring | Use |
|-------|--------|-----|
| `motionQuick` | `.spring(duration: 0.25, bounce: 0.0)` | Toggles, chip selection, hover |
| `motionStandard` | `.spring(duration: 0.35, bounce: 0.15)` | Card appearance, surface swaps |
| `motionEmphasis` | `.spring(duration: 0.5, bounce: 0.25)` | Sheet hero, approval resolution |

- List insertions/removals use `.motionStandard` with
  `.transition(.opacity.combined(with: .scale(0.98)))`.
- The composer send button animates the paper-plane "release" only when
  a send actually occurs (trigger on send count).
- Session state changes cross-fade the state chip (0.25 s).
- **Reduce Motion:** all of the above collapse to opacity-only
  transitions; hold-to-confirm ring still animates (it is progress,
  not decoration) but without scale pulse.

## 6. Haptics

Delivered via `.sensoryFeedback` (declarative) and
`UIImpactFeedbackGenerator` only for gesture-progress ticks.

| Moment | Feedback |
|--------|----------|
| Send prompt / terminal enter | `.impact(flexibility: .soft, intensity: 0.6)` |
| Approval resolved — allow | `.success` |
| Approval resolved — deny | `.warning` |
| Hold-to-confirm progress tick (each 20 %) | light impact, intensity ramps 0.3→0.8 |
| Hold-to-confirm complete | `.success` (then the resolution feedback) |
| Pairing confirmed | `.success`; rejected: `.error` |
| Circuit-breaker retry | `.impact(flexibility: .rigid, intensity: 0.5)` |
| Destructive confirm (revoke device / rule) | `.warning` on completion |

Reduce Motion does **not** disable haptics (they are confirmation, not
motion). Mute switch behavior stays system-default.

## 7. Screens

### 7.1 Tab shell

5 tabs (Home, Sessions, Approvals, Macs, Settings), system glass tab
bar, minimize-on-scroll. Approvals badge = pending count (system
badge). Degraded-store banner: full-width warning strip above content,
`deckWarning` at 90 % in light, 25 % in dark, height 28 pt + text 13 pt.

### 7.2 Home

- **Header**: 34 pt greeting ("AgentDeck"), caption connection line
  (status dot 8 pt + text). No big cards for connection — it's one line.
- **Agent grid**: 2-column grid (iPhone), 4-column (iPad regular),
  card height **96 pt**, radius 14, padding 12: agent glyph in a
  28 × 28 pt accent-tinted rounded square (radius 8), name (callout
  semibold), status line (footnote): "2 active" / "Installed" /
  "Not observed" (tertiary). Not-installed cards: glyph monochrome,
  no accent.
- **Active sessions**: full-width rows, agent accent 3 pt leading edge,
  state chip (footnote, radius 10), project name caption.
- **Quick actions**: two 50 pt glass buttons side by side —
  "New Session" (glassProminent, deckAccent) and "New Shell"
  (glass, terminal glyph). Below: text-button "Reconnect" only when
  the circuit is open.
- Empty states: `ContentUnavailableView` with the agent personality
  words, never dead ends.

### 7.3 Sessions list

Rows: 44 pt minimum height, agent glyph chip 28 pt, title = project
name (fallback agent name), subtitle = state display name + relative
time. State chips: tinted by agent accent for live states; terminal
states (completed/failed/interrupted) monochrome. Swipe action on
live sessions: Stop (warning, haptic).

### 7.4 Session detail

- **Header** (below nav bar): agent chip (glyph + name), state chip,
  per-agent accent; height 40 pt, horizontal padding 16.
- **Surface switcher**: segmented (Timeline / Terminal / Raw / Diffs),
  32 pt, margins 16 × 8.
- **Terminal**: per-agent surface from §3. Header strip 36 pt inside
  the terminal area: traffic-light dots (10 pt, 8 pt gaps) tinted to
  the agent theme, session title (monoSmall), right side
  interactive/read-only toggle (footnote). Content: SwiftTerm at
  13 pt SF Mono, background from the agent theme, 8 pt text inset.
  Corner radius 20, outer padding 12, sits on `Color.black` canvas.
- **Composer**: floating glass capsule above the keyboard-safe bottom:
  radius 20, padding h16 v10, text field 17 pt, send button 36 pt
  glassProminent in agent accent. Disabled state 40 % opacity.
- **Diffs**: banner (truncated) warning strip 32 pt; file list +
  hunk view reuse the existing browser, re-tokenized (mono 12,
  additions `deckSuccess` 16 % bg, deletions `deckDanger` 16 % bg).
- Haptics: send (soft impact), approval resolve (success/warning).

### 7.5 Approvals

- Inbox rows: risk badge (icon + word, capsule, risk color at 20 %
  background), explanation 2-line, mono action 1-line, expiry caption.
- Detail: hero card (radius 20, padding 20): explanation 22 semibold,
  exact action in mono 12 block (radius 10, padding 12, quaternary bg),
  files/domains as mono lists.
- Decision dock (sticky bottom, glass): Deny (glass, danger text),
  Allow Once (glassProminent, deckAccent).
- **Hold-to-confirm** (critical only): full-width 50 pt control; a
  circular progress ring (44 pt) fills over 0.8 s with tick haptics;
  label cross-fades "Hold to Allow…" → "Release to Confirm". Uses
  `motionQuick` for the press scale (0.97), haptic ramp per §6.

### 7.6 Macs

Device cards (radius 14): Mac glyph (`desktopcomputer`) 28 pt chip,
name, `deviceID` short form mono 12, "Revoked" danger caption or
Revoke button (borderless, danger, with confirmation dialog + haptic).
Pair section: "Scan QR Code" 50 pt glassProminent; paste field in a
radius-14 block; Pair button disabled until payload non-empty.

### 7.7 Settings

Grouped list, token spacing; no glass (system grouped style). Rows:
Device ID (mono 12, copyable), Connection status + Reconnect, store
degradation warning, About. Diagnostics section header uses footnote
secondary text explaining what each row means.

### 7.8 Pairing confirmation sheet

System sheet (large detent). Hero: `person.badge.key.fill` 44 pt in
accent. Phrase block: mono 17 pt, letter-spaced, radius 14, quaternary
background, padding 16, selectable. Fingerprint mono 12. Actions:
Reject (glass, danger) / Confirm (glassProminent, success) — 50 pt,
side by side, haptics per §6. Swipe-to-dismiss disabled (fail closed).

## 8. Accessibility contract

- Every color signal has an icon or text twin (risk, state, connection).
- All text styles are Dynamic Type; layout survives 135 % text size
  (cards grow vertically, grids stay 2-column until 190 %).
- Reduce Motion: §5 collapse rules.
- Reduce Transparency: glass effects degrade to system materials
  automatically (we never read the setting manually; system handles it).
- VoiceOver: agent cards expose one combined element
  ("Claude Code, installed, 2 active sessions, button"); terminal is
  labeled "Terminal output" with the raw-output surface as its
  accessible alternative.

## 9. What we deliberately do NOT do

- No custom tab bar implementation (system glass is the point of iOS 26).
- No parallax, no particle effects, no animated gradients on headers.
- No neon/glow shadows behind cards; depth comes from material, not
  shadow stacks (shadows: at most `Color.black.opacity(0.08)`, 8 pt
  radius, on floating composer only).
- No fake terminal scanlines or CRT effects. The terminals are tools.
- No per-agent fonts — SF Pro + SF Mono everywhere; personality comes
  from color and chrome, not typography novelty.
