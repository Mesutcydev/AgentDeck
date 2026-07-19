#!/usr/bin/env bash
# Verified fallback installer for AgentDeck Companion.
set -euo pipefail

REPOSITORY="${AGENTDECK_REPOSITORY:-Mesutcydev/AgentDeck}"
RELEASE_BASE="https://github.com/${REPOSITORY}/releases/latest/download"
INSTALL_ROOT="${AGENTDECK_INSTALL_ROOT:-/Applications}"
if [[ ! -w "${INSTALL_ROOT}" ]]; then
  INSTALL_ROOT="${HOME:?}/Applications"
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentdeck-install.XXXXXX")"
MOUNT_DIR="${TEMP_DIR}/mount"
DMG="${TEMP_DIR}/AgentDeck-Companion.dmg"
CHECKSUM="${TEMP_DIR}/AgentDeck-Companion.dmg.sha256"
cleanup() {
  if mount | grep -Fq "on ${MOUNT_DIR} "; then hdiutil detach "${MOUNT_DIR}" -quiet || true; fi
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT INT TERM

mkdir -p "${MOUNT_DIR}" "${INSTALL_ROOT}" "${HOME:?}/.local/bin"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "${RELEASE_BASE}/AgentDeck-Companion.dmg" -o "${DMG}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "${RELEASE_BASE}/AgentDeck-Companion.dmg.sha256" -o "${CHECKSUM}"

EXPECTED="$(awk 'NF { print $1; exit }' "${CHECKSUM}")"
ACTUAL="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
[[ "${EXPECTED}" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Invalid release checksum" >&2; exit 1; }
[[ "${ACTUAL}" == "${EXPECTED}" ]] || { echo "AgentDeck checksum verification failed" >&2; exit 1; }

hdiutil attach "${DMG}" -mountpoint "${MOUNT_DIR}" -nobrowse -quiet
APP="${MOUNT_DIR}/AgentDeck Companion.app"
[[ -d "${APP}" ]] || { echo "Release does not contain AgentDeck Companion.app" >&2; exit 1; }
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")"
[[ "${IDENTIFIER}" == "com.agentdeck.companion" ]] || { echo "Unexpected app identity" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "${APP}"
xcrun stapler validate "${APP}"
spctl --assess --type execute --verbose=2 "${APP}"

TARGET="${INSTALL_ROOT}/AgentDeck Companion.app"
rm -rf "${TARGET}.installing"
/usr/bin/ditto "${APP}" "${TARGET}.installing"
rm -rf "${TARGET}"
mv "${TARGET}.installing" "${TARGET}"
ln -sfn "${TARGET}/Contents/Resources/agentdeck" "${HOME}/.local/bin/agentdeck"

echo "Installed AgentDeck Companion in ${TARGET}"
echo "CLI: ${HOME}/.local/bin/agentdeck"
if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  echo "Add ${HOME}/.local/bin to PATH to run 'agentdeck'."
fi
