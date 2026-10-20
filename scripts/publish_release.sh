#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
TAG="${1:?Usage: publish_release.sh TAG}"
VERSION="${TAG#v}"
ASSETS=()
for arch in universal x86_64 arm64; do
  asset="build/IMELocker-v${VERSION}-${arch}.dmg"
  [[ -f "${asset}" ]] || { echo "error: Missing ${asset}" >&2; exit 1; }
  ASSETS+=("${asset}")
done

if IS_DRAFT="$(gh release view "${TAG}" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
  if [[ "${IS_DRAFT}" == false ]]; then
    echo "Release ${TAG} is already published; preserving its existing assets."
    exit 0
  fi
  [[ "${IS_DRAFT}" == true ]] || { echo 'error: Unexpected release state' >&2; exit 1; }
else
  IS_DRAFT=missing
fi

NOTES_FILE="docs/releases/${TAG}.md"
if [[ ! -f "${NOTES_FILE}" ]]; then
  NOTES_FILE="$(mktemp)"
  trap 'rm -f "${NOTES_FILE}"' EXIT
fi
if [[ "${IS_DRAFT}" == missing ]]; then
  gh release create "${TAG}" --draft --verify-tag --title "${TAG}" --notes-file "${NOTES_FILE}"
fi
# Only draft assets may be replaced. Failure leaves the release unpublished.
gh release upload "${TAG}" "${ASSETS[@]}" --clobber
gh release edit "${TAG}" --draft=false --notes-file "${NOTES_FILE}"
