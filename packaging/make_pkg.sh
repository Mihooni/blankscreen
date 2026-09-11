#!/bin/bash
# 构建 macOS 安装包（.pkg）
#
# 产物:  build/pkgout/LidKeep-<version>.pkg
# 内容:  /Applications/LidKeep.app + /usr/local/bin/lidkeep
#
# 用法:  ./packaging/make_pkg.sh [版本号]
#        版本号缺省时取最近的 git tag（去 v 前缀）
set -e
cd "$(dirname "$0")/.."

# 关键：禁止 cp 生成 ._xxx AppleDouble 元数据文件。
# 否则 payload 里会混进 ._lidkeep / ._usr / ._CodeSignature 之类的垃圾文件，
# 既污染安装包，又可能在安装后留下无意义的隐藏文件。
export COPYFILE_DISABLE=1

VER="${1:-}"
VER="${VER#v}"          # 兼容传入 v1.1.1 这样的 tag
if [ -z "$VER" ]; then
  # CI 里 fetch-depth 可能不含 tag，此时由调用方显式传入版本号
  VER=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
fi
[ -z "$VER" ] && VER="1.1.1"

IDENT="com.lidkeep"
STAGE="build/pkg"
OUT="build/pkgout"
COMP="$STAGE/LidKeep-component.pkg"

echo "==> 版本号: $VER"

# 确保已构建（make all 产出 universal 二进制）
if [ ! -f build/lidkeep ] || [ ! -d build/LidKeep.app ]; then
  echo "==> 未发现构建产物，先执行 make all"
  make all >/dev/null
fi

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/payload/usr/local/bin" \
         "$STAGE/payload/Applications" \
         "$STAGE/scripts" \
         "$STAGE/resources" \
         "$OUT"

# ---- 组装 payload ----
cp build/lidkeep "$STAGE/payload/usr/local/bin/lidkeep"
chmod 755 "$STAGE/payload/usr/local/bin/lidkeep"
cp -R build/LidKeep.app "$STAGE/payload/Applications/"
# 清掉 AppleDouble / .DS_Store 等杂项，避免打进包里
find "$STAGE/payload" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
REMAIN=$(find "$STAGE/payload" -name '._*' 2>/dev/null | wc -l | tr -d ' ')
echo "==> payload 中残留的 ._ 元数据文件: $REMAIN"

# 尽量清掉扩展属性（如 com.apple.quarantine）。
# 注：com.apple.provenance 是系统保护属性，无法删除；pkgbuild 会为带 xattr 的条目
# 生成 ._ AppleDouble 归档条目——这是 macOS 在 pkg 中承载扩展属性的标准机制，
# 安装时会还原为 xattr 而非落地成文件，属正常现象。
# ad-hoc 代码签名嵌在 Mach-O 内，不受 xattr 清理影响。
xattr -cr "$STAGE/payload" 2>/dev/null || true

# ---- 组件包 ----
cp packaging/scripts/postinstall "$STAGE/scripts/postinstall"
chmod 755 "$STAGE/scripts/postinstall"

# ---- 安装器资源（许可 / 说明）----
cp LICENSE "$STAGE/resources/LICENSE.txt"
cp packaging/README-install.html "$STAGE/resources/README-install.html"
sed "s/__VERSION__/$VER/g" packaging/Distribution.xml > "$STAGE/Distribution.xml"

echo "==> 构建组件包"
pkgbuild --identifier "$IDENT" \
         --version "$VER" \
         --install-location / \
         --root "$STAGE/payload" \
         --scripts "$STAGE/scripts" \
         "$COMP"

# ---- 产品归档（带许可协议与说明的安装器 UI）----
FINAL="$OUT/LidKeep-$VER.pkg"
echo "==> 打包安装器"
if productbuild --distribution "$STAGE/Distribution.xml" \
                --package-path "$STAGE" \
                --resources "$STAGE/resources" \
                "$FINAL" 2>/dev/null; then
  echo "==> 已生成（含许可协议）: $FINAL"
else
  # productbuild 失败时退回组件包，保证总有可用产物
  echo "==> productbuild 不可用/失败，回退为组件包"
  cp "$COMP" "$FINAL"
  echo "==> 已生成: $FINAL"
fi

# ---- 自检 ----
echo "==> 校验安装包内容"
pkgutil --payload-files "$COMP" | sed 's/^/    /' | head -20
echo
ls -lh "$FINAL"
