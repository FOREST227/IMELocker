#!/usr/bin/env bash
set -euo pipefail

# ./build.sh [--target universal|arm64|x86_64|all]
TARGET_VALUE=universal
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != --target ]]; then
    echo '用法: ./build.sh [--target universal|arm64|x86_64|all]' >&2
    exit 1
  fi
  TARGET_VALUE="$2"
fi
case "${TARGET_VALUE}" in
  universal|arm64|x86_64|all) ;;
  *) echo "error: unsupported target: ${TARGET_VALUE}" >&2; exit 1 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
BIN_DIR="${BUILD_DIR}/bin"
MODULE_CACHE_DIR="${BUILD_DIR}/ModuleCache"
APP_BUNDLE_NAME="输入法锁定"
APP_EXEC_NAME="InputSourceLock"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "${BIN_DIR}" "${MODULE_CACHE_DIR}/arm64" "${MODULE_CACHE_DIR}/x86_64"
SWIFT_SOURCES=("${ROOT_DIR}"/src/*.swift)

compile() {
  local arch="$1"
  swiftc -O -sdk "${SDK_PATH}" \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    -module-cache-path "${MODULE_CACHE_DIR}/${arch}" \
    -target "${arch}-apple-macosx12.0" \
    -o "${BIN_DIR}/${APP_EXEC_NAME}-${arch}" "${SWIFT_SOURCES[@]}"
}

case "${TARGET_VALUE}" in
  arm64|x86_64) compile "${TARGET_VALUE}" ;;
  universal|all)
    compile arm64 &
    ARM_PID=$!
    compile x86_64 &
    X86_PID=$!
    BUILD_FAILED=0
    wait "${ARM_PID}" || BUILD_FAILED=1
    wait "${X86_PID}" || BUILD_FAILED=1
    if [[ "${BUILD_FAILED}" -ne 0 ]]; then
      echo 'error: Both arm64 and x86_64 are required. Check the selected Xcode/toolchain; no universal package was produced.' >&2
      exit 1
    fi
    lipo -create -output "${BIN_DIR}/${APP_EXEC_NAME}-universal" \
      "${BIN_DIR}/${APP_EXEC_NAME}-arm64" "${BIN_DIR}/${APP_EXEC_NAME}-x86_64"
    ;;
esac

make_bundle() {
  local arch="$1" app_dir="$2"
  rm -rf "${app_dir}"
  mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources" "${app_dir}/Contents/Frameworks"
  cp "${ROOT_DIR}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
  cp "${ROOT_DIR}/Resources/AppIcon.icns" "${app_dir}/Contents/Resources/AppIcon.icns"
  cp "${BIN_DIR}/${APP_EXEC_NAME}-${arch}" "${app_dir}/Contents/MacOS/${APP_EXEC_NAME}"
  if STD_TOOL="$(xcrun --find swift-stdlib-tool 2>/dev/null)"; then
    "${STD_TOOL}" --copy --scan-executable "${app_dir}/Contents/MacOS/${APP_EXEC_NAME}" \
      --destination "${app_dir}/Contents/Frameworks" --platform macosx --strip-bitcode
  fi
  while IFS= read -r -d '' lib; do
    codesign --force --sign - "${lib}"
  done < <(find "${app_dir}/Contents/Frameworks" \( -name '*.dylib' -o -name '*.framework' \) -print0)
  codesign --force --sign - "${app_dir}"
  bash "${ROOT_DIR}/scripts/verify_app.sh" "${app_dir}" "${arch}"
  echo "Built: ${app_dir} (${arch})"
}

if [[ "${TARGET_VALUE}" == all ]]; then
  for arch in arm64 x86_64 universal; do
    make_bundle "${arch}" "${BUILD_DIR}/${arch}/${APP_BUNDLE_NAME}.app"
  done
else
  make_bundle "${TARGET_VALUE}" "${BUILD_DIR}/${APP_BUNDLE_NAME}.app"
fi
