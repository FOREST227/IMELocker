#!/usr/bin/env bash
set -euo pipefail
APP_PATH="$1"
TARGET="$2"
BINARY="${APP_PATH}/Contents/MacOS/InputSourceLock"
ACTUAL_ARCHS="$(lipo -archs "${BINARY}")"
case "${TARGET}" in
  universal) EXPECTED_ARCHS='arm64 x86_64' ;;
  arm64|x86_64) EXPECTED_ARCHS="${TARGET}" ;;
  *) echo "error: unsupported architecture: ${TARGET}" >&2; exit 1 ;;
esac
NORMALIZED_ACTUAL="$(printf '%s\n' ${ACTUAL_ARCHS} | LC_ALL=C sort | tr '\n' ' ')"
NORMALIZED_EXPECTED="$(printf '%s\n' ${EXPECTED_ARCHS} | LC_ALL=C sort | tr '\n' ' ')"
if [[ "${NORMALIZED_ACTUAL}" != "${NORMALIZED_EXPECTED}" ]]; then
  echo "error: Expected ${EXPECTED_ARCHS}, found ${ACTUAL_ARCHS}" >&2
  exit 1
fi
codesign --verify --deep --strict "${APP_PATH}"
