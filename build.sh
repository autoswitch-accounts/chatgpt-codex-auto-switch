#!/bin/bash
# 从源码生成「ChatGPT 账号.app」
#   ./build.sh               编译到 build/，装进 /Applications，并（重新）启动自动切号后台服务
#   ./build.sh --no-install  只编译到 build/（打包发布用，见 scripts/package.sh）
#
# 签名：默认用无身份签名（ad-hoc），App 里不带任何开发者信息。
# 想用自己的证书：设环境变量 SIGN_IDENTITY，或把证书名 / SHA-1 写进 signing.local（已在 .gitignore 里）。
set -euo pipefail
cd "$(dirname "$0")"

NAME="ChatGPT 账号"
BUNDLE_ID="com.local.chatgpt.manager"
VERSION="${VERSION:-5.0}"
MIN_MACOS="14.0"        # 最低系统；macOS 26 上用 Liquid Glass，14 / 15 退回系统原有样式（见 App/Compat.swift）
OUT="build/$NAME.app"
APP="/Applications/$NAME.app"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f signing.local ]; then IDENTITY="$(tr -d '[:space:]' < signing.local)"; fi
IDENTITY="${IDENTITY:--}"

/usr/bin/python3 -m py_compile engine.py autoswitch.py
rm -rf "$OUT" __pycache__
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos$MIN_MACOS -parse-as-library App/*.swift -o "$OUT/Contents/MacOS/ChatGPTAccounts"
cp engine.py autoswitch.py "$OUT/Contents/Resources/"
cp Assets/appicon.icns "$OUT/Contents/Resources/appicon.icns"   # 图标由 Assets/make_icon.swift 生成
# 界面文字：中文原文当键，en.lproj 放英文译文；zh-Hans.lproj 只放 App 名（中文直接用键本身）
for l in App/*.lproj; do
    cp -R "$l" "$OUT/Contents/Resources/"
    for f in "$OUT/Contents/Resources/$(basename "$l")"/*; do plutil -lint -s "$f"; done
done

# 系统菜单（关于 / 隐藏 / 退出 / 编辑）跟着 App 声明的语言走：中文界面是中文菜单，英文界面是英文菜单
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>ChatGPTAccounts</string>
  <key>CFBundleIconFile</key><string>appicon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign "$IDENTITY" "$OUT"

if [ "${1:-}" = "--no-install" ]; then
    echo "已编译：$OUT"
    exit 0
fi

# 整包替换（正在运行的那个进程不受影响，下次打开就是新版）
rm -rf "$APP"
ditto "$OUT" "$APP"
# 后台服务的 plist 指向 App 里的 autoswitch.py；内容变了会重装，没变也强制重启让新代码生效
/usr/bin/python3 "$APP/Contents/Resources/engine.py" --ensure-daemon --restart
echo "已安装：$APP"
