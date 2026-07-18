#!/bin/bash
#
# scripts/ci.sh — AgentDeck one-shot CI entry point (SPEC §27).
#
# Runs the full headless contract in order: build.sh (all targets, zero
# warnings) then test.sh (Shared + Companion + Relay suites). Any failure
# stops the run with a non-zero exit.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$REPO_ROOT/scripts/build.sh"
"$REPO_ROOT/scripts/test.sh"

echo "==> ci.sh OK (build + test contracts green)"
