#!/bin/bash
#
# scripts/test.sh — AgentDeck headless test contract (SPEC §27).
#
# Runs:
#   1. Packages/Shared tests (swift test, host macOS)
#   2. CompanionTests (xcodebuild test, app-hosted in Companion.app)
#   3. Relay tests (swift test, host macOS)
# Warnings are defects (SPEC §25): warnings are treated as errors. Runs
# from a clean checkout with the pinned toolchain (ARCHITECTURE.md §1).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/Shared"
DERIVED_DATA="$REPO_ROOT/DerivedData"

# Agent/CI sandboxes often set HOME to a temp dir with no login keychain.
# SecKey, TLS, and DeviceIdentity tests require the real user's keychain.
if [[ ! -d "${HOME}/Library/Keychains" ]]; then
    REAL_HOME="$(dscl . -read "/Users/$(whoami)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    if [[ -n "$REAL_HOME" && -d "$REAL_HOME/Library/Keychains" ]]; then
        export HOME="$REAL_HOME"
    fi
fi

pkill -9 -f "$PACKAGE_DIR/.build/[^ ]*SharedPackageTests\.xctest/Contents/MacOS/SharedPackageTests" 2>/dev/null || true

echo "==> Running Shared tests (swift test, warnings as errors, HOME=$HOME)"
SHARED_TEST_LOG="$(mktemp)"
swift test \
    --package-path "$PACKAGE_DIR" \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -strict-concurrency=complete \
    2>&1 | tee "$SHARED_TEST_LOG"
if grep -q '✘ Test run' "$SHARED_TEST_LOG"; then
    echo "==> Shared tests FAILED (swift test reported issues)"
    rm -f "$SHARED_TEST_LOG"
    exit 1
fi
rm -f "$SHARED_TEST_LOG"

echo "==> Running Companion tests (xcodebuild test, warnings as errors)"
# NOTE: warnings-as-errors for the Companion lives in the pbxproj target
# settings; passing SWIFT_TREAT_WARNINGS_AS_ERRORS on this command line
# conflicts with SwiftPM's -suppress-warnings for package targets.
cd "$REPO_ROOT"
xcodebuild \
    -project AgentDeck.xcodeproj \
    -scheme Companion \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    test

# Surface the live SMAppService evidence captured by LoginItemLiveTests
# (app-hosted test stdout is not echoed by xcodebuild).
EVIDENCE_FILE="${TMPDIR:-/tmp}/agentdeck-loginitem-evidence.log"
if [ -f "$EVIDENCE_FILE" ]; then
    echo "==> Live SMAppService evidence (CompanionTests/LoginItemLiveTests)"
    cat "$EVIDENCE_FILE"
    echo ""
fi

echo "==> Running Relay tests (swift test, warnings as errors)"
RELAY_TEST_LOG="$(mktemp)"
swift test \
    --package-path "$REPO_ROOT/Relay" \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -strict-concurrency=complete \
    2>&1 | tee "$RELAY_TEST_LOG"
if grep -q '✘ Test run' "$RELAY_TEST_LOG"; then
    echo "==> Relay tests FAILED"
    rm -f "$RELAY_TEST_LOG"
    exit 1
fi
rm -f "$RELAY_TEST_LOG"

echo "==> test.sh OK (zero warnings)"
