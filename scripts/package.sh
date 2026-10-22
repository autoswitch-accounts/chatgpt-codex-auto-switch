#!/bin/bash
# 打发布包：用无身份签名编译，压成 dist/ChatGPT-Accounts-<版本>.zip，传到 GitHub Releases 即可
#   VERSION=5.1 scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-5.0}"
SIGN_IDENTITY=- VERSION="$VERSION" ./build.sh --no-install
mkdir -p dist
ZIP="dist/ChatGPT-Accounts-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "build/ChatGPT 账号.app" "$ZIP"
codesign -dv "build/ChatGPT 账号.app" 2>&1 | grep -q "TeamIdentifier=not set" || { echo "签名里带了开发者信息，不发布" >&2; exit 1; }
shasum -a 256 "$ZIP"
