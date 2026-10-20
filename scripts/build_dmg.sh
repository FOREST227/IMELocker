#!/usr/bin/env bash
set -euo pipefail
# ./scripts/build_dmg.sh [VERSION] [universal|arm64|x86_64] [--skip-build]
# --skip-build reuses build/<architecture>/ from build.sh --target all.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="输入法锁定"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Resources/Info.plist")"
VERSION="${1:-${PLIST_VERSION}}"
TARGET="${2:-universal}"
if [[ $# -gt 3 || ( $# -eq 3 && "$3" != --skip-build ) ]]; then
  echo 'error: expected [VERSION] [TARGET] [--skip-build]' >&2; exit 1
fi
case "${TARGET}" in
  arm64|x86_64|universal) ;;
  *) echo "error: unsupported target: ${TARGET}" >&2; exit 1 ;;
esac
if [[ "${VERSION}" != "${PLIST_VERSION}" ]]; then
  echo "error: Release ${VERSION} does not match Info.plist ${PLIST_VERSION}; update the source version before packaging." >&2
  exit 1
fi

if [[ "${3:-}" == --skip-build ]]; then
  APP_PATH="${BUILD_DIR}/${TARGET}/${APP_NAME}.app"
else
  bash "${ROOT_DIR}/build.sh" --target "${TARGET}"
  APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [[ "${APP_VERSION}" != "${VERSION}" ]]; then
  echo "error: Built app version ${APP_VERSION} does not match ${VERSION}" >&2; exit 1
fi
bash "${ROOT_DIR}/scripts/verify_app.sh" "${APP_PATH}" "${TARGET}"

DMG_PATH="${BUILD_DIR}/IMELocker-v${VERSION}-${TARGET}.dmg"
STAGING_DIR="$(mktemp -d "${BUILD_DIR}/dmg-root.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov \
  -format UDZO -imagekey zlib-level=9 "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
echo "Built: ${DMG_PATH}"
