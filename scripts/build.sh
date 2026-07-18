#!/bin/bash
#
# scripts/build.sh — AgentDeck headless build contract (SPEC §27).
#
# Builds:
#   1. Packages/Shared for macOS (swift build)
#   2. Packages/Shared for iOS (xcodebuild, generic destination)
#   3. Companion macOS app (xcodebuild, AgentDeck.xcodeproj)
# Warnings are defects (SPEC §25): every build treats warnings as errors.
# Runs from a clean checkout with the pinned toolchain (ARCHITECTURE.md §1).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/Shared"
DERIVED_DATA="$REPO_ROOT/DerivedData"

echo "==> Toolchain"
xcodebuild -version
swift --version

echo "==> Building Shared for macOS (swift build, warnings as errors)"
swift build \
    --package-path "$PACKAGE_DIR" \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -strict-concurrency=complete

echo "==> Building Shared for iOS (xcodebuild, warnings as errors)"
cd "$PACKAGE_DIR"
# Proof, not log-scraping: wipe this leg's products first, then require the
# iphoneos swiftmodule to exist afterwards. Grepping the build log is flaky —
# on an incremental no-op build xcodebuild prints no Debug-iphoneos compile
# lines even though the leg genuinely targets the iOS SDK. (This leg used to
# print "Supported platforms for the buildables in the current scheme is
# empty" and exit 0 without compiling anything for iOS.)
rm -rf "$DERIVED_DATA/Shared-iOS/Build"
xcodebuild \
    -scheme Shared \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA/Shared-iOS" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    SWIFT_STRICT_CONCURRENCY=complete \
    build
IOS_SWIFTMODULE="$DERIVED_DATA/Shared-iOS/Build/Products/Debug-iphoneos/Shared.swiftmodule/arm64-apple-ios.swiftmodule"
if [ ! -f "$IOS_SWIFTMODULE" ]; then
    echo "==> Shared iOS build FAILED: no iphoneos SDK artifact at $IOS_SWIFTMODULE"
    exit 1
fi

echo "==> Building Companion for macOS (xcodebuild, warnings as errors)"
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
    build

echo "==> Building App for iOS Simulator (xcodebuild, warnings as errors)"
# NOTE: warnings-as-errors for the App lives in the pbxproj target settings;
# passing SWIFT_TREAT_WARNINGS_AS_ERRORS on this command line conflicts with
# SwiftPM's -suppress-warnings for package targets.
# SIMULATOR_DEST overrides the destination (e.g. a locally available device).
SIMULATOR_DEST="${SIMULATOR_DEST:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"
cd "$REPO_ROOT"
xcodebuild \
    -project AgentDeck.xcodeproj \
    -scheme App \
    -destination "$SIMULATOR_DEST" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "==> Building agentdeck-relay (swift build, warnings as errors)"
swift build \
    --package-path "$REPO_ROOT/Relay" \
    -c release \
    --product agentdeck-relay \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -strict-concurrency=complete

echo "==> build.sh OK (Shared macOS + iOS, Companion macOS, App iOS Simulator, Relay — zero warnings)"
