# AgentDeck Release Audit

Audit date: 2026-07-18

## Verified

- iOS generic-device Release build succeeds with signing disabled, including the app, widget, privacy manifests, final app icon, and animated splash.
- Companion Release build succeeds with Hardened Runtime and an Apple Development signature.
- The installed `/Applications/AgentDeck Companion.app` passes deep, strict code-signature verification.
- Companion unit tests pass with the renamed product and stable `Companion` Swift module.
- Shared package tests pass: 251 tests across 61 suites.
- CLI discovery finds and version-probes installed Claude, Codex, Grok, Kimi, and OpenCode executables without relying on a shell application's inherited `PATH`.
- Session history is persisted in SQLite and exposed as searchable session memory in both apps.
- Approval policies and notification relay settings are backed by live repositories/configuration; update controls are hidden when Sparkle has no feed.
- Production iOS UI no longer seeds demo sessions, approvals, diffs, or terminal events.
- iOS and widget privacy manifests are embedded in their release bundles. The Companion privacy manifest is embedded in its app bundle.
- `git diff --check` passes.

## Distribution blockers outside the repository

### TestFlight

The source is configured for production push notifications and App Store privacy metadata, but a signed archive cannot be produced on this Mac until:

1. The Apple developer account is reauthenticated in Xcode.
2. Explicit App IDs are provisioned for `com.agentdeck.app` and `com.agentdeck.app.widget`.
3. The `group.com.agentdeck.shared` App Group and Push Notifications capability are enabled in the provisioning profiles.
4. A valid Apple Distribution identity/profile is installed.

### macOS notarization

The installed Companion is development-signed and hardened, but is not notarized. Notarization requires a Developer ID Application identity and valid notary credentials; neither is installed on this Mac. Once supplied, archive with Developer ID, submit with `notarytool`, staple the accepted ticket, and re-run `codesign --verify` plus Gatekeeper assessment.
