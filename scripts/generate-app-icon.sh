#!/bin/bash
# 仅生成本工程资源，不操作已安装 App 或用户图标缓存。
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/keydock-icon.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/AppIcon.iconset"
xcrun swift scripts/render-app-icon.swift "$scratch/source.png"
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" "$scratch/source.png" --out "$scratch/AppIcon.iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" "$scratch/source.png" --out "$scratch/AppIcon.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil --convert icns "$scratch/AppIcon.iconset" --output "$scratch/AppIcon.icns"
test -s "$scratch/AppIcon.icns"
cp "$scratch/AppIcon.icns" Apps/KeyDock/Resources/AppIcon.icns
echo 'Generated Apps/KeyDock/Resources/AppIcon.icns (16–1024 px).'
