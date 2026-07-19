#!/usr/bin/env bash
# Package the macOS companion into a stapled-ready DMG (Phase 15).
# Requires Developer ID credentials (NEEDS-HUMAN #2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/DerivedData/Build/Products/Release"
APP="$BUILD_DIR/AgentDeck Companion.app"
DMG="$REPO_ROOT/dist/AgentDeck-Companion.dmg"

mkdir -p "$REPO_ROOT/dist"
hdiutil create -volname "AgentDeck Companion" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created $DMG (notarization/stapling requires NEEDS-HUMAN #2 credentials)"
