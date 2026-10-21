#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT
SOURCES=()
for source in "${ROOT_DIR}"/src/*.swift; do
  [[ "$(basename "${source}")" == main.swift ]] || SOURCES+=("${source}")
done
swiftc -framework Cocoa -framework Carbon -framework ServiceManagement \
  "${SOURCES[@]}" "${ROOT_DIR}/tests/RegressionTests.swift" "${ROOT_DIR}/tests/MenuTests.swift" -o "${TEST_DIR}/regression-tests"
"${TEST_DIR}/regression-tests"
swift "${ROOT_DIR}/tests/IconTests.swift"
python3 -m unittest discover -s "${ROOT_DIR}/tests" -p 'test_*.py'
