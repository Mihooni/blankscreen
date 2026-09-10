#!/bin/bash
# blankscreen 一键构建安装（= make install）
# 可选: ./install.sh --cli-only   只安装命令行工具
#
# 提示语言跟随系统（与 App / CLI 一致），与软件本体同一套判定逻辑。
set -e
cd "$(dirname "$0")"

# 系统语言是否为中文：先看 shell 的 LANG/LC_ALL，再问 macOS 的首选语言列表
ZH=0
case "${LANG:-}${LC_ALL:-}" in *zh*) ZH=1 ;; esac
if [ "$ZH" -eq 0 ] && defaults read -g AppleLanguages 2>/dev/null | grep -q '"zh'; then
  ZH=1
fi
m() { if [ "$ZH" -eq 1 ]; then echo "$1"; else echo "$2"; fi; }   # m "中文" "English"

if [ "$(uname)" != "Darwin" ]; then
  m "错误: blankscreen 只能在 macOS 上构建运行。" \
    "Error: blankscreen can only be built and run on macOS." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  m "错误: 未找到 swiftc。请先安装 Xcode Command Line Tools:" \
    "Error: swiftc not found. Install Xcode Command Line Tools first:" >&2
  echo "      xcode-select --install" >&2
  exit 1
fi

if [ "$1" = "--cli-only" ]; then
  make cli
  sudo make install-cli 2>/dev/null || {
    mkdir -p "$HOME/.local/bin"
    install -m 0755 build/blankscreen "$HOME/.local/bin/blankscreen"
    m "已安装到 ~/.local/bin/blankscreen（确保该目录在 PATH 中）" \
      "Installed to ~/.local/bin/blankscreen (make sure it is on your PATH)"
  }
else
  make install
fi
