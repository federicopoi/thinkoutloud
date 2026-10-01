#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_SOURCE="$PWD/dist/Think Out Loud.app"
APP_DEST="$HOME/Applications/Think Out Loud.app"
if pgrep -x LocalDictation >/dev/null || pgrep -x ThinkOutLoud >/dev/null; then
    printf 'Quit Think Out Loud from its menu bar icon before installing an update.\n'
    exit 1
fi
if [ ! -d "$APP_SOURCE" ]; then
    printf 'Build first: bash scripts/build.sh\n'
    exit 1
fi
mkdir -p "$HOME/Applications"
# Retain one app identity and its existing microphone permission/preferences.
LEGACY_APPS=()
for candidate in "$HOME/Applications/Speak.app" "$HOME/Applications/Local Dictation.app"; do
    if [ -d "$candidate" ]; then
        LEGACY_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
        if [ "$LEGACY_ID" != "com.fedepoi.localdictation" ]; then
            printf 'The old app has an unexpected identity; leaving it untouched.\n'
            exit 1
        fi
        LEGACY_APPS+=("$candidate")
    fi
done
if [ "${#LEGACY_APPS[@]}" -gt 1 ] || { [ "${#LEGACY_APPS[@]}" -gt 0 ] && [ -e "$APP_DEST" ]; }; then
    printf 'Multiple installed app names exist. Resolve the duplicate before installing.\n'
    exit 1
fi
if [ "${#LEGACY_APPS[@]}" -eq 1 ]; then
    mv "${LEGACY_APPS[0]}" "$APP_DEST"
fi
ditto "$APP_SOURCE" "$APP_DEST"
# Remove only the obsolete executable left by the app's in-place rename.
if [ -f "$APP_DEST/Contents/MacOS/LocalDictation" ]; then
    rm "$APP_DEST/Contents/MacOS/LocalDictation"
fi
codesign --verify --strict "$APP_DEST"
printf 'Installed: %s\nLaunch: open "%s"\n' "$APP_DEST" "$APP_DEST"
