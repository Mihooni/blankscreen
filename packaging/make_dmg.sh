#!/bin/bash
# 构建 macOS 拖拽安装镜像（.dmg）
#
# 产物:  build/dmgout/LidKeep-<version>.dmg
# 内容:  LidKeep.app（拖到 Applications 即装）
#        + Applications 快捷方式
#        + lidkeep 命令行工具
#        + Install Command-Line Tool.command（双击弹出系统密码框装 CLI / double-click to install the CLI）
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

STAGE="build/dmg/LidKeep"
OUT="build/dmgout"

echo "==> 版本号: $VER"

if [ ! -f build/lidkeep ] || [ ! -d build/LidKeep.app ]; then
  echo "==> 未发现构建产物，先执行 make all"
  make all >/dev/null
fi

rm -rf build/dmg "$OUT"
mkdir -p "$STAGE" "$OUT"

# ---- 组装镜像内容 ----
cp -R build/LidKeep.app "$STAGE/"
cp build/lidkeep "$STAGE/"
chmod 755 "$STAGE/lidkeep"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Install Command-Line Tool.command" << 'EOF'
#!/bin/sh
# Double-click to install lidkeep into the Homebrew prefix (one admin password prompt)
cd "$(dirname "$0")" || exit 1
if [ "$(uname -m)" = "arm64" ]; then DEST=/opt/homebrew/bin; else DEST=/usr/local/bin; fi
if osascript -e "do shell script \"mkdir -p $DEST && cp -f lidkeep '$DEST/lidkeep'\" with administrator privileges"; then
  osascript -e "display dialog \"✅ Installed: $DEST/lidkeep\n\nTry it: lidkeep nosleep setup\" buttons {\"OK\"} default button 1 with title \"LidKeep\""
else
  osascript -e "display dialog \"❌ Cancelled or installation failed\" buttons {\"OK\"} default button 1 with title \"LidKeep\""
fi
EOF
chmod 755 "$STAGE/Install Command-Line Tool.command"

cat > "$STAGE/Read Me.txt" << 'EOF'
LidKeep — turn the display off without putting the Mac to sleep.
LidKeep —— 关屏但不睡眠

Install / 安装:
  1. Drag LidKeep.app into the Applications folder on the right
     把 LidKeep.app 拖进右边的 Applications 文件夹
  2. (Optional) Double-click "Install Command-Line Tool.command" to install the CLI,
     then run: lidkeep nosleep setup
     （可选）双击「Install Command-Line Tool.command」装好 CLI，然后执行
     lidkeep nosleep setup 一键开启防睡眠

Click the ☀ / 🌙 menu bar icon to toggle the display; anti-sleep and settings live in the same menu.
菜单栏图标 ☀ / 🌙 即可开关显示器；防睡眠与设置都在菜单里。

The interface follows your system language (English / Chinese).
界面语言跟随系统（中 / 英）。
EOF

# 清掉 AppleDouble / .DS_Store，避免污染镜像
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
xattr -cr "$STAGE" 2>/dev/null || true

# ---- 生成 DMG（UDZO 压缩，只读）----
FINAL="$OUT/LidKeep-$VER.dmg"
echo "==> 生成 DMG"
hdiutil create -volname "LidKeep $VER" \
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
