# AgentDeck Privacy Policy (draft)

Last updated: 2026-07-18.

## What stays on your Mac

- **Pairing keys and identities** live in the macOS Keychain as generic-password items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — they never sync off the device. This covers the device identity key, the TLS identity, and the notification-relay signing key.
- **Session data** — session metadata, timeline events, approval rules, and approval audit entries — is stored in a local SQLite database under `~/Library/Application Support/AgentDeck/`. It never leaves the Mac except across your own paired connection to your own devices.
- **Agent processes** run as your logged-in user with your own permissions; AgentDeck adds no daemon and runs nothing as root.

## What your iOS devices cache

- The iOS app mirrors session events, approvals, and session metadata received from your paired Mac into local on-device storage so timelines survive disconnects.
- The home-screen widget reads a sanitized summary (`WidgetSummaryState`) from the shared App Group container — counts and status only, no code, prompts, or terminal output.
- Pairing keys on iOS live in the iOS Keychain, this-device-only.

## What the notification relay sees

Background alerts travel through a developer-operated relay. The relay
receives only the fixed §14.3 payload schema, per request:

- an opaque push destination token (no device identity),
- an event type from a closed set (e.g. `approval_required`, `session_completed`),
- an opaque session identifier,
- an optional project alias,
- notification text (pre-redacted on the Mac, at most 256 characters),
- an expiration timestamp and an Ed25519 signature.

The relay rejects anything outside this schema — terminal output, source
code, prompts, file contents, environment values, and credentials are
forbidden fields with automated test coverage. Requests are additionally
body-capped, replay-protected, and rate-limited. The current relay keeps
deliveries only in an in-memory buffer (delivery is simulated) and persists
nothing.

## Attachments

Attachments move only over your paired phone ↔ Mac connection, are staged
with safe generated filenames (no shell interpolation), and are never sent
to the notification relay.

## Diagnostics export

Exporting diagnostics is always your explicit action (save panel). The
export is a redacted JSON snapshot: status fields plus recent diagnostic
lines that were scrubbed by the Redactor before storage — no secrets, no
code, no terminal output. The in-memory diagnostics buffer holds at most
500 entries and is never sent anywhere automatically.

## Analytics and third parties

AgentDeck contains no analytics, no tracking, and no crash-reporting SDK.
The only outbound network calls are ones you configure: your paired
devices, an optional notification relay endpoint, and optional update
checks (Sparkle, https only, once an appcast is configured).

Contact: support@agentdeck.example (replace before distribution — NEEDS-HUMAN #6).
