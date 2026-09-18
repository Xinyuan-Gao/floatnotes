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

# 写进构建时间戳。之前被「到底开的是哪一版」坑过一次 ——
# 磁盘上留着旧副本，光看外观分不出新旧。现在菜单栏「关于」里就能看到。
STAMP="$(date +%Y%m%d.%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STAMP" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $STAMP" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STAMP" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $STAMP" "$APP/Contents/Info.plist"

echo "▸ [4/4] 签名"
SIGN_ID="FloatNotes Local Signing"
KC="$HOME/Library/Keychains/floatnotes-signing.keychain-db"
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$SIGN_ID"; then
  security unlock-keychain -p "floatnotes" "$KC" >/dev/null 2>&1 || true
  if codesign --force --deep -i com.xy.floatnotes --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
    echo "   已用稳定身份签名（重新构建不会丢屏幕录制授权）"
  else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
      && echo "   ⚠️ 稳定身份签名失败，回退 ad-hoc（授权可能需重给）" \
      || echo "   签名跳过"
  fi
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "   ad-hoc 签名（跑 tools/setup-signing.sh 可换成稳定身份）" \
    || echo "   签名跳过"
fi

echo
echo "✅ 打包完成：${APP}（构建 ${STAMP}）"
du -sh "$APP" | awk '{print "   体积：" $1}'
