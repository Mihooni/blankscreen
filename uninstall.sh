#!/bin/bash
# lidkeep 完整卸载
cd "$(dirname "$0")"

ZH=0
case "${LANG:-}${LC_ALL:-}" in *zh*) ZH=1 ;; esac
if [ "$ZH" -eq 0 ] && defaults read -g AppleLanguages 2>/dev/null | grep -q '"zh'; then
  ZH=1
fi
m() { if [ "$ZH" -eq 1 ]; then echo "$1"; else echo "$2"; fi; }

make uninstall

echo
m "如需同时清除配置与日志（热键设置会丢失）:" \
  "To also remove config and logs (your hotkey settings will be lost):"
echo "  rm -rf ~/Library/Application\\ Support/LidKeep"
