#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/.build/swiftc"
APP_BUNDLE="${REPO_ROOT}/Ticker.app"

cd "${REPO_ROOT}"

rm -rf "${BUILD_DIR}" "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}"

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -emit-module -module-name TickerCore \
    -emit-module-path "${BUILD_DIR}/TickerCore.swiftmodule" \
    -emit-library -static -o "${BUILD_DIR}/libTickerCore.a" \
    Sources/TickerCore/*.swift Sources/TickerCore/Adapters/*.swift

swiftc -target arm64-apple-macosx13.0 \
    -I "${BUILD_DIR}" -L "${BUILD_DIR}" -lTickerCore -lsqlite3 \
    -o "${BUILD_DIR}/ticker" Sources/ticker/main.swift

swiftc -target arm64-apple-macosx13.0 -parse-as-library \
    -I "${BUILD_DIR}" -L "${BUILD_DIR}" -lTickerCore -lsqlite3 \
    -o "${BUILD_DIR}/TickerApp" Sources/TickerApp/*.swift

mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/TickerApp" "${APP_BUNDLE}/Contents/MacOS/Ticker"
cp "${BUILD_DIR}/ticker" "${APP_BUNDLE}/Contents/MacOS/ticker"

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

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --verbose "${APP_BUNDLE}"

printf 'Built %s (%s)\n' "${APP_BUNDLE}" "$(du -sh "${APP_BUNDLE}" | cut -f1)"
