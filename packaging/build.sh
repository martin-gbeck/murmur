#!/bin/bash
# Build and package Murmur.app.
#
#   ./packaging/build.sh                 → dist/Murmur.app, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" ./packaging/build.sh
#                                        → Developer ID signed (hardened runtime)
#   ARCHS="arm64 x86_64" not supported in v1; arm64 only.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release --arch arm64

APP=dist/Murmur.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> assembling bundle"
cp .build/arm64-apple-macosx/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> codesign"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

codesign --verify --verbose=2 "$APP"
echo "==> done: $APP"
