# Phase 12 Profiling Report (ADR-0018)

Measured on 2026-07-18 with `./scripts/build.sh` + `./scripts/test.sh` on Apple Silicon.

| Budget (§23) | Target | Observed | Status |
|---|---|---|---|
| Shared test suite | < 10 s typical | ~4–6 s | pass |
| Full build | headless CI | ~60 s | pass |
| Pairing loopback | ≤ 10 s LAN | ~1 s loopback | pass (LAN NEEDS-HUMAN #10) |

No UI jank profiling on simulator in this headless run; iPad split layouts use native `NavigationSplitView` without custom blur materials.
