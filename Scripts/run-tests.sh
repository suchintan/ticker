#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ticker-tests.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

cd "${REPO_ROOT}"

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -lsqlite3 -o "${BUILD_DIR}/TickerTests" \
    Sources/TickerCore/*.swift Sources/TickerCore/Adapters/*.swift Tests/TickerTests.swift

"${BUILD_DIR}/TickerTests"
