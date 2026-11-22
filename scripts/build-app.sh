#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
smoke=false
if [[ "${1:-}" == --safe-smoke ]]; then smoke=true; elif [[ -n "${1:-}" ]]; then printf '%s\n' 'Unknown build option' >&2; exit 1; fi
xcodegen generate --spec project.yml
xcodebuild -project KeyDock.xcodeproj -scheme KeyDock -configuration Debug -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
app_path="$PWD/build/DerivedData/Build/Products/Debug/KeyDock.app"
/usr/libexec/PlistBuddy -c "Delete :KeyDockSafeSmoke" "$app_path/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :KeyDockSafeSmoke bool $smoke" "$app_path/Contents/Info.plist"
codesign --force --sign - --identifier com.arthurwangwsx.KeyDock "$app_path"
printf 'Built %s\n' "$app_path"
