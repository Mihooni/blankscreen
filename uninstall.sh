#!/bin/bash
# blankscreen 完整卸载
cd "$(dirname "$0")"
make uninstall

echo
echo "如需同时清除配置与日志（热键设置会丢失）:"
echo "  rm -rf ~/Library/Application\\ Support/blankscreen"
