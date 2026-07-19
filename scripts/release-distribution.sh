#!/usr/bin/env bash
# Produces all channel metadata from one verified version. Publication is
# downstream of this script and therefore cannot precede signature/notarization.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release-distribution.sh VERSION TAG DMG APP}"
TAG="${2:?usage: release-distribution.sh VERSION TAG DMG APP}"
DMG="${3:?usage: release-distribution.sh VERSION TAG DMG APP}"
APP="${4:?usage: release-distribution.sh VERSION TAG DMG APP}"
OUTPUT="${REPO_ROOT}/dist/release-metadata"
SPARKLE_ARCHIVES="${OUTPUT}/sparkle"

codesign --verify --deep --strict --verbose=2 "${APP}"
SIGNING_INFO="$(codesign -dv --verbose=4 "${APP}" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<<"${SIGNING_INFO}" || {
  echo "Refusing publication: Developer ID Application signature required" >&2; exit 1;
}
xcrun stapler validate "${APP}"
spctl --assess --type execute --verbose=2 "${APP}"
xcrun stapler validate "${DMG}"

mkdir -p "${OUTPUT}"
SHA256="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
printf '%s  %s\n' "${SHA256}" "$(basename "${DMG}")" > "${OUTPUT}/AgentDeck-Companion.dmg.sha256"
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__TAG__/${TAG}/g" -e "s/__SHA256__/${SHA256}/g" \
  "${REPO_ROOT}/distribution/Casks/agentdeck.rb.template" > "${OUTPUT}/agentdeck.rb"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ "${APP_VERSION}" == "${VERSION}" ]] || {
  echo "Refusing publication: requested version ${VERSION} does not match app ${APP_VERSION}" >&2; exit 1;
}

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "${GENERATE_APPCAST}" ]]; then
  GENERATE_APPCAST="$(find "${REPO_ROOT}/DerivedData" "${REPO_ROOT}/.build" -type f -name generate_appcast -perm +111 -print -quit 2>/dev/null || true)"
fi
[[ -x "${GENERATE_APPCAST}" ]] || { echo "Sparkle generate_appcast was not found" >&2; exit 1; }
: "${SPARKLE_PRIVATE_KEY_FILE:?Set SPARKLE_PRIVATE_KEY_FILE to the EdDSA private key file}"
[[ -f "${SPARKLE_PRIVATE_KEY_FILE}" ]] || { echo "Sparkle private key file is missing" >&2; exit 1; }

rm -rf "${SPARKLE_ARCHIVES}"
mkdir -p "${SPARKLE_ARCHIVES}"
cp "${DMG}" "${SPARKLE_ARCHIVES}/AgentDeck-Companion-${VERSION}.dmg"
"${GENERATE_APPCAST}" \
  --ed-key-file "${SPARKLE_PRIVATE_KEY_FILE}" \
  --download-url-prefix "https://github.com/Mesutcydev/AgentDeck/releases/download/${TAG}/" \
  -o appcast.xml \
  "${SPARKLE_ARCHIVES}"
cp "${SPARKLE_ARCHIVES}/appcast.xml" "${OUTPUT}/appcast.xml"

cat > "${OUTPUT}/installer.json" <<EOF
{
  "version": "${VERSION}",
  "tag": "${TAG}",
  "bundleIdentifier": "com.agentdeck.companion",
  "dmg": "https://github.com/Mesutcydev/AgentDeck/releases/download/${TAG}/AgentDeck-Companion.dmg",
  "sha256": "${SHA256}",
  "checksum": "https://github.com/Mesutcydev/AgentDeck/releases/download/${TAG}/AgentDeck-Companion.dmg.sha256",
  "installer": "https://github.com/Mesutcydev/AgentDeck/releases/download/${TAG}/install.sh"
}
EOF

echo "Verified checksum, Sparkle appcast, Homebrew Cask, and installer metadata in ${OUTPUT}"
echo "Publish agentdeck.rb to Mesutcydev/homebrew-agentdeck only after the GitHub release assets are live."
