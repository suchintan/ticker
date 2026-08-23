#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ticker-tests.XXXXXX")"
MODULE_CACHE_DIR="${BUILD_DIR}/module-cache"
trap 'rm -rf "${BUILD_DIR}"' EXIT

cd "${REPO_ROOT}"

/usr/bin/python3 -m unittest discover -s Tests -p 'test_run_codex_scheduled_task.py'
/usr/bin/python3 -m unittest discover -s Tests -p 'test_migrate_claude_routines_to_codex.py'

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    -D TICKER_TESTING \
    -lsqlite3 -o "${BUILD_DIR}/TickerTests" \
    Sources/TickerCore/*.swift Sources/TickerCore/Adapters/*.swift Tests/TickerTests.swift

"${BUILD_DIR}/TickerTests"
