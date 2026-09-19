#!/bin/bash
# 创建一个稳定的本地代码签名身份。
#
# 为什么要这个：
#   ad-hoc 签名的 designated requirement 是 `cdhash H"..."`，而 cdhash 随二进制变化
#   —— 每重新构建一次，系统就当成另一个 App。后果是「屏幕录制」授权每次都要重给，
#   而且系统设置里会挂着一堆同名条目，显示「已开启」但对当前这份不生效。
#
#   换成自签名证书之后，DR 变成
#     identifier "com.xy.floatnotes" and certificate root = H"<证书哈希>"
#   证书和 bundle id 都不变，所以授权一次就长期有效。
#
# 这个脚本是幂等的，重复跑不会重复建。
set -euo pipefail

KC_NAME="floatnotes-signing"
KC="$HOME/Library/Keychains/${KC_NAME}.keychain-db"
CERT_CN="FloatNotes Local Signing"
KC_PASS="floatnotes"          # 本地开发用钥匙串，密码固定写在脚本里
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ 钥匙串: $KC"

# ── 0. 钥匙串存在但密码对不上？自己重建 ──────────────
#    踩过的坑：钥匙串里的私钥被 partition list 挡着，而改 partition list 必须要密码。
#    一旦密码和脚本里写的不一致（换过机器、被系统改过、老版本脚本留下的），
#    就成了「身份看得见、就是签不了名」的死局，构建时静默回退 ad-hoc，
#    用户那边表现为屏幕录制授权莫名其妙失效。宁可重建，也不要留这种半死状态。
if [ -f "$KC" ]; then
    if security unlock-keychain -p "$KC_PASS" "$KC" 2>/dev/null; then
        echo "  ✓ 钥匙串可解锁"
    else
        echo "  ⚠️ 钥匙串密码对不上，删除重建（旧证书作废，屏幕录制授权需要重给一次）"
        security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
    fi
fi

# ── 1. 身份不存在才创建 ──────────────────────────────
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$CERT_CN"; then
    echo "  ✓ 签名身份已存在，跳过创建"
else
    echo "▸ 创建自签名代码签名证书"
    security delete-keychain "$KC" 2>/dev/null || true
    security create-keychain -p "$KC_PASS" "$KC"
    # 试过 -t 0 -u，这台机器上 SecKeychainSetSettings 一律回「User canceled the operation」
    # （改钥匙串设置要走 GUI 授权）。它只影响「睡眠后是否重新上锁」，不影响签名，
    # 所以失败就失败，别用 set -e 把整个脚本带走 —— 之前就是这么中断在建证书之前的。
    security set-keychain-settings -t 0 -u "$KC" 2>/dev/null || true
    security unlock-keychain -p "$KC_PASS" "$KC"

    # 必须带 codeSigning 扩展用途，否则不能用来签代码
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -subj "/CN=$CERT_CN/O=FloatNotes" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" 2>/dev/null

    # ★ 必须用 -legacy：OpenSSL 3 默认的 AES-256 加密 macOS 的 security import 读不了，
    #   会报 "MAC verification failed during PKCS12 import"
    openssl pkcs12 -export -legacy -out "$TMP/cert.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$KC_PASS" 2>/dev/null

    security import "$TMP/cert.p12" -k "$KC" -P "$KC_PASS" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KC_PASS" "$KC" >/dev/null 2>&1 || true

    # 不设为信任的话，codesign 会报 CSSMERR_TP_NOT_TRUSTED / no identity found
    security add-trusted-cert -r trustRoot -k "$KC" "$TMP/cert.pem"
    echo "  ✓ 证书已创建并设为信任"
fi

# ── 2. 必须在 codesign 的搜索列表里 ──────────────────
#    注意：`codesign --keychain <路径>` 实测不管用，必须挂到搜索列表。
if security list-keychains -d user | grep -q "$KC_NAME"; then
    echo "  ✓ 已在钥匙串搜索列表里"
else
    ORIG=$(security list-keychains -d user | sed 's/^[[:space:]]*//;s/"//g' | tr '\n' ' ')
    # shellcheck disable=SC2086
    security list-keychains -d user -s $ORIG "$KC"
    echo "  ✓ 已加入钥匙串搜索列表"
fi

# ── 3. 每次都重新解锁并修好 partition list ───────────
#    光靠 import 时的 -T /usr/bin/codesign 不够：新版 macOS 还要求
#    partition list 里带 apple: 和 codesign:，否则 codesign 报 errSecInternalComponent
#    —— 那个错误看起来像「钥匙串锁了」，实际是权限没给够，很容易查错方向。
security unlock-keychain -p "$KC_PASS" "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PASS" "$KC" >/dev/null

echo
echo "✅ 完成。构建脚本会自动使用这个身份。"
security find-identity -v -p codesigning "$KC" | head -2
echo
echo "证书根哈希（决定屏幕录制授权的长期有效性，重建后会变）："
security find-certificate -c "$CERT_CN" -a -Z "$KC" | awk '/SHA-1 hash/ {print "  "$0; exit}'
