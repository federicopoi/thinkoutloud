#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP_PATH="$PWD/dist/Think Out Loud.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/LocalDictation "$APP_PATH/Contents/MacOS/ThinkOutLoud"
cp resources/Info.plist "$APP_PATH/Contents/Info.plist"
# Share the exact native logo path with the icon generator.
cat Sources/LocalDictation/Brand.swift scripts/make-icon.swift > .build/make-icon.swift
swift .build/make-icon.swift "$APP_PATH/Contents/Resources"
codesign --force --sign - --options runtime --entitlements resources/entitlements.plist "$APP_PATH"
codesign --verify --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
