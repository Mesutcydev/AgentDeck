# AgentDeck Connection Release Audit

Date: 2026-07-19

## Release decision

Connection state is suitable for device testing after build 15. Production background-alert reliability remains conditional on deploying and configuring the notification relay.

## Verified

- The Home, Macs, and Settings connection labels derive from live authenticated sockets, not pairing records.
- Revoking or forgetting a Mac closes its transport before changing persistence and clears selected-host state.
- New shells and agent launches route only to the selected live Mac. They never fall back to another paired endpoint.
- Foreground activation restarts the reconnect state machine, resumes sessions from persisted cursors, and requests fresh project and agent snapshots.
- Reconnect uses capped exponential backoff with jitter and a circuit breaker rather than a tight retry loop.
- Companion can prevent automatic idle system sleep through a persisted user setting.
- AgentDeck has the required local-network privacy description. VampHost's multicast entitlement is not copied because AgentDeck uses a QR-pinned IP endpoint rather than Bonjour discovery.
- Shared transport, pairing, session, approval, and security suites pass (265 tests), and the iOS application builds successfully.
- Companion source and release configuration compile successfully. The app-hosted Companion test runner is currently blocked on this Mac by a development-team signature mismatch between the host and test bundle; this is a release-process issue to correct before claiming a completely green macOS test run.

## Lock-screen behavior

iOS does not guarantee a long-running local TCP connection after the app enters the background or the phone locks. AgentDeck therefore deliberately closes the foreground socket, persists event cursors, and reconnects when the app becomes active. Missed events are replayed from the last persisted cursor.

Approval, completion, and failure alerts while locked use APNs through the redacting notification relay. The Companion remains the source of truth and continues owning provider processes and PTYs.

## Remaining production gate

The relay URL is optional and currently user-configured. Without a deployed HTTPS relay and a saved relay URL, the locked iPhone receives no background approval/completion alerts. Before public release:

1. Deploy the relay behind TLS with APNs credentials.
2. Ship a trusted production relay URL or complete explicit setup during onboarding.
3. Verify push token registration on a physical iPhone.
4. Run a 30-minute locked-phone test covering approval, completion, reconnect, replay, and duplicate suppression.
5. Test Wi-Fi to cellular transition and Tailnet endpoint loss.

## Prevent-sleep scope

“Prevent Mac from Sleeping” uses a macOS process activity assertion to block automatic idle system sleep while Companion runs. It intentionally cannot override closing the lid, manual Sleep, restart, shutdown, battery exhaustion, or network loss.
