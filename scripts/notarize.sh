#!/usr/bin/env bash
# Notarize and staple the companion DMG (Phase 15).
# Requires: NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$REPO_ROOT/dist/AgentDeck-Companion.dmg"

: "${NOTARY_APPLE_ID:?Set NOTARY_APPLE_ID}"
: "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID}"
: "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD}"

xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
xcrun stapler staple "$DMG"
echo "Notarized and stapled $DMG"
