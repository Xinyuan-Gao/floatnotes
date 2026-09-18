#!/bin/bash
# 生成 App 图标：渲染 PNG → iconutil 打包成 .icns → 放到 Resources/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.iconbuild"
OUT="$ROOT/Resources/AppIcon.icns"

echo "▸ 渲染图标各尺寸"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$ROOT/Resources"
swiftc -O "$ROOT/tools/IconGenerator.swift" -o "$BUILD/genicon"
"$BUILD/genicon" "$BUILD"

echo "▸ 打包 .icns"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$OUT"

rm -rf "$BUILD"
echo
echo "✅ 图标已生成：$OUT"
ls -lh "$OUT" | awk '{print "   体积：" $5}'
