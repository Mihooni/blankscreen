#!/bin/bash
# blankscreen 一键构建安装（= make install）
# 可选: ./install.sh --cli-only   只安装命令行工具
set -e
cd "$(dirname "$0")"

if [ "$(uname)" != "Darwin" ]; then
  echo "错误: blankscreen 只能在 macOS 上构建运行。" >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误: 未找到 swiftc。请先安装 Xcode Command Line Tools:" >&2
  echo "      xcode-select --install" >&2
  exit 1
fi

if [ "$1" = "--cli-only" ]; then
  make cli
  sudo make install-cli 2>/dev/null || { mkdir -p "$HOME/.local/bin"; install -m 0755 build/blankscreen "$HOME/.local/bin/blankscreen"; echo "已安装到 ~/.local/bin/blankscreen（确保该目录在 PATH 中）"; }
else
  make install
fi
