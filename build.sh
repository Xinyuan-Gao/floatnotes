#!/bin/bash
# 无 Xcode 打包脚本：SPM 编译 → 手工组装 .app bundle → ad-hoc 签名
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/悬浮笔记.app"
CONFIG="${1:-release}"

echo "▸ [1/4] 构建编辑器（Vite 单文件）"
cd "$ROOT/editor-src"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build

echo "▸ [2/4] 编译 Swift ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FloatNotes"

echo "▸ [3/4] 组装 .app bundle"
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "   图标缺失，自动生成…"
  "$ROOT/tools/make-icon.sh" >/dev/null
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/editor"
cp "$BIN" "$APP/Contents/MacOS/FloatNotes"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/editor-src/dist/index.html" "$APP/Contents/Resources/editor/index.html"

echo "▸ [4/4] ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "   签名完成" || echo "   签名跳过（自用无妨）"

echo
echo "✅ 打包完成：$APP"
du -sh "$APP" | awk '{print "   体积：" $1}'
