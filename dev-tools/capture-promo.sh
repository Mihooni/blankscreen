#!/bin/bash
# 采集推广素材：菜单截图、设置面板截图、演示动图
#
# GUI 点击需要「辅助功能」权限，脚本无法自动点开菜单，所以每项都留出倒计时，
# 由你在倒计时内手动操作，脚本负责截取/录制与转码。
#
# 用法：
#   ./capture-promo.sh menu        # 菜单展开截图
#   ./capture-promo.sh settings    # 设置面板截图
#   ./capture-promo.sh gif         # 录 12 秒演示并转成 GIF
#   ./capture-promo.sh all

set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/docs/promo"
mkdir -p "$OUT"

need_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 || {
    echo "缺少 ffmpeg。装一下：brew install ffmpeg" >&2
    exit 1
  }
}

# 倒计时，给用户时间把界面摆到目标状态
countdown() {
  local n="${1:-5}"
  while [ "$n" -gt 0 ]; do
    printf '\r  %s 秒后截取…（现在就操作）' "$n"
    sleep 1
    n=$((n - 1))
  done
  printf '\r'
}

do_menu() {
  echo "【菜单截图】"
  echo "  请在这几秒内点开菜单栏的 LidKeep 图标，让菜单停在那里不要动。"
  echo "  提示：点一下图标松开即可，菜单会保持展开。"
  countdown 6
  screencapture -x "$OUT/.menu-full.png"
  echo "  已截取整屏：$OUT/.menu-full.png"
  echo "  接着请手动裁出菜单区域（预览.app 按 ⌘K 裁剪），另存为："
  echo "    $OUT/menu.png"
  echo "  整屏文件含你的桌面内容，用完请删除。"
}

do_settings() {
  echo "【设置面板截图】"
  echo "  请在这几秒内从菜单打开「设置…」，让窗口停在屏幕上。"
  countdown 6
  screencapture -x -o "$OUT/.settings-full.png"
  echo "  已截取整屏：$OUT/.settings-full.png"
  echo "  裁出设置窗口后另存为："
  echo "    $OUT/settings.png"
  echo "  整屏文件含你的桌面内容，用完请删除。"
}

do_gif() {
  need_ffmpeg
  echo "【演示动图】"
  echo "  将录制 12 秒。建议流程："
  echo "    1. 点开菜单，让四种电源模式都露出来"
  echo "    2. 点「关闭显示器」→ 屏幕全黑"
  echo "    3. 按热键 ⌃⌥⌘B 恢复"
  echo "  注意：屏幕真的会黑掉，录制期间你看不到画面，按热键即可恢复。"
  echo ""
  read -r -p "  准备好后按回车开始录制…" _
  sleep 2
  screencapture -x -V 12 "$OUT/.demo.mov"
  echo "  录制完成，转 GIF 中…"
  ffmpeg -y -loglevel error -i "$OUT/.demo.mov" \
    -vf "fps=12,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
    -loop 0 "$OUT/demo.gif"
  ls -lh "$OUT/demo.gif"
  echo "  已生成：$OUT/demo.gif"
  echo "  原始 .mov 保留在 $OUT/.demo.mov，含完整桌面，发帖前请删除。"
}

case "${1:-all}" in
  menu)     do_menu ;;
  settings) do_settings ;;
  gif)      do_gif ;;
  all)      do_menu; do_settings; do_gif ;;
  *)        sed -n '2,14p' "$0"; exit 1 ;;
esac

echo ""
echo "完成。产物在：$OUT"
