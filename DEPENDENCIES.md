# DEPENDENCIES.md — third-party dependency register

Policy (SPEC §26): system frameworks only by default. A third-party dependency is allowed only if **all** hold: Swift Package Manager distribution; permissive license (MIT/BSD/Apache-2.0); maintained (commit within last 12 months); no transitive networking or analytics; pinned exact version; recorded here with justification; ADR in `DECISIONS.md`.

## Current dependencies

### SwiftTerm 1.13.0
- Integrated: 2026-07-17, Phase 5, App target (iOS)
- License: MIT (verified 2026-07-17)
- Justification: SPEC §26 pre-approved terminal engine; wrapped behind `TerminalEngine` protocol in Shared and SwiftTerm UI in App
- Transitive networking/analytics: none (verified: terminal rendering library only)
- ADR: pre-approved, SPEC §26

### SwiftNIO 2.101.3
- Integrated: 2026-07-18, Phase 10, Relay target only (`agentdeck-relay`)
- License: Apache-2.0 (verified 2026-07-18)
- Justification: SPEC §14.3 single-binary relay HTTP server; system URLSession is insufficient for the long-lived relay service
- Transitive networking/analytics: none for relay usage (NIO core + HTTP/1 only; no analytics SDKs)
- ADR: ADR-0016

### Sparkle 2.9.4
- Integrated: 2026-07-18, Phase 15 completion, Companion target only
- Status: **integrated; inert until `SUFeedURL`/`SUPublicEDKey` are configured (NEEDS-HUMAN)** — a real EdDSA appcast signing key and hosted https appcast must be supplied by a human; the feed URL is read from Info.plist (`SPARKLE_FEED_URL` overrides for development, https only)
- License: MIT (verified 2026-07-18)
- Justification: SPEC §7/§20.3 EdDSA-signed appcast updates; manual "Check for Updates" + optional automatic checks when `SUFeedURL` is set
- Transitive networking/analytics: none for update checks only (HTTPS appcast fetch; no analytics SDKs)
- ADR: pre-approved, SPEC §26

## Pre-approved, not yet integrated

Pre-approval waives the per-dependency ADR (SPEC §26) but not this register entry. Integration happens in the phase listed; exact version pin recorded at integration time.

| Dependency | Purpose (scope-limited) | Phase | Justification |
|---|---|---|---|
| SwiftTerm | Terminal engine, wrapped behind an internal `TerminalEngine` protocol; app targets only | 5 | SPEC §26 forbids writing a terminal emulator from scratch; SwiftTerm is the designated engine, MIT-licensed, SPM-distributable, actively maintained. **Integrated in Phase 5 (App target, v1.13.0).** |
| Sparkle 2 | Companion app update delivery; **companion target only** | 15 | SPEC §7/§20.3 mandate EdDSA-signed appcast updates; Sparkle 2 is the de-facto standard, BSD-licensed, SPM-distributable. **Integrated in Phase 15 completion (Companion target, v2.9.4).** |
| SwiftNIO | HTTP server for the notification relay; **relay target only** | 10 | SPEC §14.3 specifies the relay as a single-binary Swift service with "no framework requirement beyond SwiftNIO"; Apache-2.0, Apple-maintained. **Integrated in Phase 10 (Relay target, v2.101.3).** |

## Register entries

All integrated dependencies are listed under **Current dependencies** above.

The local `agentdeck` executable, Unix-domain socket server, external-session discovery, Homebrew Cask template, and verified fallback installer use only Swift/Foundation, Darwin, Security, and standard macOS command-line tools; they add no third-party dependency.
