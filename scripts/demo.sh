#!/bin/bash
# 用一份假数据打开 App：看界面、截图用。不联网，不碰真实账号、ChatGPT 和后台服务。
#   scripts/demo.sh                      假数据放在 /tmp/chatgpt-accounts-demo
#   scripts/demo.sh --page members       App 参数原样传过去（--page overview|accounts|teams|members|sessions|messages|logs|settings）
#   scripts/demo.sh -AppleLanguages '(en)'   英文界面，假数据（名字、日志、消息、对话标题）也换成英文
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/ChatGPT 账号.app"
[ -x "$APP/Contents/MacOS/ChatGPTAccounts" ] || ./build.sh --no-install
DEMO="${DEMO_HOME:-/tmp/chatgpt-accounts-demo}"
rm -rf "$DEMO"
LANG_ARG=zh
prev=""
for a in "$@"; do
    if [ "$prev" = "-AppleLanguages" ]; then case "$a" in *en*) LANG_ARG=en ;; esac; fi
    prev="$a"
done
DEMO_LANG="$LANG_ARG" /usr/bin/python3 scripts/demo_data.py "$DEMO" >/dev/null
HOME="$DEMO" CGA_DEMO=1 exec "$APP/Contents/MacOS/ChatGPTAccounts" "$@"
