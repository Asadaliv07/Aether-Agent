#!/usr/bin/env bash
# ==============================================================================
# Aether Production Release & Packaging Pipeline
# ==============================================================================
# Supports:
#   1. Clean Release compilation via xcodebuild (Apple Silicon arm64)
#   2. Nested codesigning for llama.framework & main application bundle
#   3. Developer ID Application signing with hardened runtime when available
#   4. Transparent ad-hoc signing fallback when credentials are absent
#   5. High-compression DMG generation with /Applications symlink
#   6. Apple Notary Service submission & stapling (xcrun notarytool) when configured
#   7. Gatekeeper assessment (spctl) & SHA-256 artifact verification
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
DIST_DIR="${PROJECT_ROOT}/dist"
APP_NAME="Aether"
SCHEME="Aether"
CONFIGURATION="Release"
DESTINATION="platform=macOS,arch=arm64"
ENTITLEMENTS="${PROJECT_ROOT}/Aether/Resources/Aether.entitlements"
DMG_NAME="Aether-v1.0.0-arm64.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg_staging"

echo "======================================================================"
echo "  Aether Production Release & Packaging"
echo "  Target: macOS 14.0+ (Apple Silicon arm64)"
echo "======================================================================"
echo "Project Root: ${PROJECT_ROOT}"
echo "Distribution: ${DIST_DIR}"
echo ""

# ------------------------------------------------------------------------------
# 1. Determine Code Signing Identity
# ------------------------------------------------------------------------------
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

if [[ -z "${SIGN_IDENTITY}" ]]; then
    # Attempt to auto-discover Developer ID Application identity from login keychain
    DISCOVERED_ID=$(security find-identity -p codesigning -v 2>/dev/null | grep "Developer ID Application:" | head -n 1 | awk -F '"' '{print $2}' || true)
    if [[ -n "${DISCOVERED_ID}" ]]; then
        SIGN_IDENTITY="${DISCOVERED_ID}"
        echo "[Signing] Auto-discovered Developer ID Application: ${SIGN_IDENTITY}"
    else
        SIGN_IDENTITY="-"
        echo "[Signing] No Developer ID Application certificate found in Keychain."
        echo "[Signing] Using ad-hoc signing ('-'). Binary will run locally and require Gatekeeper evaluation override for third-party distribution."
    fi
else
    echo "[Signing] Using configured Developer ID Application: ${SIGN_IDENTITY}"
fi

# ------------------------------------------------------------------------------
# 2. Build Release Binary
# ------------------------------------------------------------------------------
echo ""
echo "[Build] Compiling Release scheme '${SCHEME}'..."
mkdir -p "${DIST_DIR}" "${BUILD_DIR}"

xcodebuild -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination "${DESTINATION}" \
    clean build \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    | xcbeautify 2>/dev/null || xcodebuild -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination "${DESTINATION}" \
    build \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"

APP_BUNDLE="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "ERROR: Application bundle not found at ${APP_BUNDLE}" >&2
    exit 1
fi
echo "[Build] Built application: ${APP_BUNDLE}"

# ------------------------------------------------------------------------------
# 3. Deep Code Signing with Framework & Hardened Runtime
# ------------------------------------------------------------------------------
echo ""
echo "[Signing] Verifying nested frameworks..."
FRAMEWORK_PATH="${APP_BUNDLE}/Contents/Frameworks/llama.framework"

if [[ -d "${FRAMEWORK_PATH}" ]]; then
    echo "[Signing] Signing nested framework: llama.framework"
    codesign --force \
        --options runtime \
        --sign "${SIGN_IDENTITY}" \
        --timestamp \
        "${FRAMEWORK_PATH}" 2>&1 || {
            echo "[Signing] Timestamping failed; falling back to non-timestamped signing..."
            codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${FRAMEWORK_PATH}"
        }
else
    echo "[Signing] Notice: llama.framework not bundled in Frameworks directory."
fi

echo "[Signing] Signing main application bundle with entitlements..."
codesign --force \
    --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    --timestamp \
    "${APP_BUNDLE}" 2>&1 || {
        echo "[Signing] Timestamping failed; falling back to non-timestamped signing..."
        codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
    }

echo "[Signing] Verifying code signature integrity..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
echo "[Signing] Signature verification passed."

# ------------------------------------------------------------------------------
# 4. Package Disk Image (DMG)
# ------------------------------------------------------------------------------
echo ""
echo "[Package] Creating distribution disk image..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"
echo "[Package] DMG created at: ${DMG_PATH}"

# Sign DMG if Developer ID is available
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "[Package] Signing DMG..."
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}" 2>&1 || \
        codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

# ------------------------------------------------------------------------------
# 5. Notarization Pipeline (xcrun notarytool)
# ------------------------------------------------------------------------------
echo ""
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    echo "[Notarization] Submitting DMG to Apple Notary Service..."
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --team-id "${APPLE_TEAM_ID}" \
        --wait

    echo "[Notarization] Stapling notarization ticket to DMG..."
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler staple "${APP_BUNDLE}"
    echo "[Notarization] Stapling completed successfully."
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    echo "[Notarization] Submitting DMG using keychain profile '${NOTARY_KEYCHAIN_PROFILE}'..."
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
        --wait

    echo "[Notarization] Stapling ticket..."
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler staple "${APP_BUNDLE}"
    echo "[Notarization] Stapling completed successfully."
else
    echo "[Notarization] Skipped (No Apple Notary credentials or Developer ID certificate provided)."
    echo "[Notarization] Distribution note: Third-party users must clear Gatekeeper quarantine via:"
    echo "    xattr -d com.apple.quarantine /Applications/Aether.app"
    echo "  or right-click -> Open in Finder."
fi

# ------------------------------------------------------------------------------
# 6. Verification and Checksum
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  Release Artifact Verification"
echo "======================================================================"

echo "Gatekeeper Assessment (spctl):"
spctl --assess --type execute -v "${APP_BUNDLE}" 2>&1 || true

echo ""
echo "Artifact Details:"
DMG_SIZE=$(stat -f "%z" "${DMG_PATH}")
DMG_SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')

echo "  File:    ${DMG_NAME}"
echo "  Path:    ${DMG_PATH}"
echo "  Size:    ${DMG_SIZE} bytes ($(( DMG_SIZE / 1024 / 1024 )) MB)"
echo "  SHA-256: ${DMG_SHA256}"
echo "======================================================================"
echo "Packaging complete!"

