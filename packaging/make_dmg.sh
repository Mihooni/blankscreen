#!/bin/bash
# 构建 macOS 拖拽安装镜像（.dmg）
#
# 产物:  build/dmgout/BlankScreen-<version>.dmg
# 内容:  BlankScreenBar.app（拖到 Applications 即装）
#        + Applications 快捷方式
#        + blankscreen 命令行工具
#        + 安装命令行工具.command（双击弹出系统密码框装 CLI）
#
# 用法:  ./packaging/make_dmg.sh [版本号]
#        版本号缺省时取最近的 git tag（去 v 前缀）
set -e
cd "$(dirname "$0")/.."

# 与 make_pkg.sh 同理：禁止 cp 生成 ._xxx AppleDouble 垃圾文件
export COPYFILE_DISABLE=1

VER="${1:-}"
VER="${VER#v}"          # 兼容传入 v1.3.1 这样的 tag
if [ -z "$VER" ]; then
  VER=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
fi
[ -z "$VER" ] && VER="1.3.1"

STAGE="build/dmg/BlankScreen"
OUT="build/dmgout"

echo "==> 版本号: $VER"

if [ ! -f build/blankscreen ] || [ ! -d build/BlankScreenBar.app ]; then
  echo "==> 未发现构建产物，先执行 make all"
  make all >/dev/null
fi

rm -rf build/dmg "$OUT"
mkdir -p "$STAGE" "$OUT"

# ---- 组装镜像内容 ----
cp -R build/BlankScreenBar.app "$STAGE/"
cp build/blankscreen "$STAGE/"
chmod 755 "$STAGE/blankscreen"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装命令行工具.command" << 'EOF'
#!/bin/sh
# 双击运行：把 blankscreen 装到 Homebrew 前缀（弹系统密码框，一次搞定）
cd "$(dirname "$0")" || exit 1
if [ "$(uname -m)" = "arm64" ]; then DEST=/opt/homebrew/bin; else DEST=/usr/local/bin; fi
if osascript -e "do shell script \"mkdir -p $DEST && cp -f blankscreen '$DEST/blankscreen'\" with administrator privileges"; then
  osascript -e "display dialog \"✅ 命令行工具已安装到 $DEST/blankscreen\n\n试试: blankscreen nosleep setup\" buttons {\"好\"} default button 1 with title \"BlankScreen\""
else
  osascript -e "display dialog \"❌ 已取消或安装失败\" buttons {\"好\"} default button 1 with title \"BlankScreen\""
fi
EOF
chmod 755 "$STAGE/安装命令行工具.command"

cat > "$STAGE/使用说明.txt" << 'EOF'
BlankScreen —— 关屏但不睡眠

安装：
  1. 把 BlankScreenBar.app 拖进右边的 Applications 文件夹
  2. （可选）双击「安装命令行工具.command」，装好 CLI 后可执行
     blankscreen nosleep setup 一键开启防睡眠

菜单栏图标 ☀ / 🌙 即可开关显示器；防睡眠与设置都在菜单里。
EOF

# 清掉 AppleDouble / .DS_Store，避免污染镜像
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
xattr -cr "$STAGE" 2>/dev/null || true

# ---- 生成 DMG（UDZO 压缩，只读）----
FINAL="$OUT/BlankScreen-$VER.dmg"
echo "==> 生成 DMG"
hdiutil create -volname "BlankScreen $VER" \
               -srcfolder "$(cd "$STAGE" && pwd)" \
               -format UDZO -ov -quiet "$FINAL"

echo "==> 自检：挂载并列出内容"
MNT="build/dmgmnt"
mkdir -p "$MNT"
hdiutil attach "$FINAL" -readonly -nobrowse -quiet -mountpoint "$(cd "$MNT" && pwd)"
ls -la "$MNT" | sed 's/^/    /'
hdiutil detach "$MNT" -quiet
rmdir "$MNT" 2>/dev/null || true

echo "==> 已生成: $FINAL"
ls -lh "$FINAL"
