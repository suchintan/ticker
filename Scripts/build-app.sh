#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/.build/swiftc"
MODULE_CACHE_DIR="${BUILD_DIR}/module-cache"
APP_BUNDLE="${REPO_ROOT}/Ticker.app"
SWIFT_CONFIGURATION_FLAGS=("-D" "TICKER_BUILD")

verify_bundle_artifacts() {
    local executable_name app_executable cli_executable app_path_key cli_path_key
    local app_swiftui_count cli_swiftui_count cli_version

    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "${APP_BUNDLE}/Contents/Info.plist")"
    app_executable="${APP_BUNDLE}/Contents/MacOS/${executable_name}"
    cli_executable="${APP_BUNDLE}/Contents/Helpers/ticker"

    if [[ ! -x "${app_executable}" ]]; then
        printf 'verify_bundle_artifacts: missing GUI executable: %s\n' "${app_executable}" >&2
        return 1
    fi
    if [[ ! -x "${cli_executable}" ]]; then
        printf 'verify_bundle_artifacts: missing CLI executable: %s\n' "${cli_executable}" >&2
        return 1
    fi

    app_path_key="$(printf '%s' "${app_executable}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    cli_path_key="$(printf '%s' "${cli_executable}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "${app_path_key}" == "${cli_path_key}" ]]; then
        printf 'verify_bundle_artifacts: GUI and CLI paths collide case-insensitively\n' >&2
        return 1
    fi
    if [[ "$(stat -f '%d:%i' "${app_executable}")" == "$(stat -f '%d:%i' "${cli_executable}")" ]]; then
        printf 'verify_bundle_artifacts: GUI and CLI resolve to the same file\n' >&2
        return 1
    fi

    app_swiftui_count="$(otool -L "${app_executable}" | awk '/SwiftUI\.framework/ { count += 1 } END { print count + 0 }')"
    cli_swiftui_count="$(otool -L "${cli_executable}" | awk '/SwiftUI\.framework/ { count += 1 } END { print count + 0 }')"
    if [[ "${app_swiftui_count}" -lt 1 ]]; then
        printf 'verify_bundle_artifacts: CFBundleExecutable is not the SwiftUI app\n' >&2
        return 1
    fi
    if [[ "${cli_swiftui_count}" -ne 0 ]]; then
        printf 'verify_bundle_artifacts: bundled CLI unexpectedly links SwiftUI\n' >&2
        return 1
    fi

    cli_version="$("${cli_executable}" --version)"
    if [[ "${cli_version}" != "ticker ${VERSION}" ]]; then
        printf 'verify_bundle_artifacts: bundled CLI returned unexpected version: %s\n' \
            "${cli_version}" >&2
        return 1
    fi

    printf 'verify_bundle_artifacts: GUI and CLI are distinct and runnable\n'
}

if [[ "${TICKER_TESTING_BUILD:-0}" == "1" ]]; then
    SWIFT_CONFIGURATION_FLAGS+=("-D" "TICKER_TESTING")
fi

cd "${REPO_ROOT}"

if [[ "${1:-}" == "--verify-only" ]]; then
    verify_bundle_artifacts
    exit 0
fi

if [[ "$#" -ne 0 ]]; then
    printf 'Usage: %s [--verify-only]\n' "$0" >&2
    exit 2
fi

rm -rf "${BUILD_DIR}" "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}"

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    "${SWIFT_CONFIGURATION_FLAGS[@]}" \
    -emit-module -module-name TickerCore \
    -emit-module-path "${BUILD_DIR}/TickerCore.swiftmodule" \
    -emit-library -static -o "${BUILD_DIR}/libTickerCore.a" \
    Sources/TickerCore/*.swift Sources/TickerCore/Adapters/*.swift

swiftc -target arm64-apple-macosx13.0 \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    "${SWIFT_CONFIGURATION_FLAGS[@]}" \
    -I "${BUILD_DIR}" -L "${BUILD_DIR}" -lTickerCore -lsqlite3 \
    -o "${BUILD_DIR}/ticker" Sources/ticker/main.swift

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    "${SWIFT_CONFIGURATION_FLAGS[@]}" \
    -I "${BUILD_DIR}" -L "${BUILD_DIR}" -lTickerCore -lsqlite3 \
    -o "${BUILD_DIR}/TickerApp" Sources/TickerApp/*.swift

mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Helpers" \
    "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/TickerApp" "${APP_BUNDLE}/Contents/MacOS/Ticker"
cp "${BUILD_DIR}/ticker" "${APP_BUNDLE}/Contents/Helpers/ticker"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.suchintan.ticker</string>
    <key>CFBundleName</key>
    <string>Ticker</string>
    <key>CFBundleExecutable</key>
    <string>Ticker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

verify_bundle_artifacts
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --verbose "${APP_BUNDLE}"

printf 'Built %s (%s)\n' "${APP_BUNDLE}" "$(du -sh "${APP_BUNDLE}" | cut -f1)"
