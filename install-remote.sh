#!/bin/bash
# LidKeep 一键安装（给终端用户，不需要 Xcode）
#
#   curl -fsSL https://raw.githubusercontent.com/Mihooni/lidkeep/main/install-remote.sh | bash
#
# 想先看清楚再跑（推荐）：
#   curl -fsSL .../install-remote.sh -o /tmp/lk.sh && less /tmp/lk.sh && bash /tmp/lk.sh
#
# 做四件事：下载 → 校验 SHA256 → 装 App 到 /Applications → 清掉 Gatekeeper 隔离标记。
# 全程可加 --no-launch 只装不启动。

set -u

REPO="Mihooni/lidkeep"
DEFAULT_VERSION="2.2.0"
# 实测（2026-09-11，中国大陆）：直连 GitHub Release 资产 10 秒 0 字节，
# gh-proxy.com 173 KB/s 且 SHA256 与官方 SHA256SUMS 逐字节一致，故作为首选回退。
MIRRORS=(
  "https://github.com/${REPO}/releases/download"
  "https://gh-proxy.com/https://github.com/${REPO}/releases/download"
  "https://ghfast.top/https://github.com/${REPO}/releases/download"
)

ZH=0
case "${LANG:-}${LC_ALL:-}" in *zh*) ZH=1 ;; esac
if [ "$ZH" -eq 0 ] && defaults read -g AppleLanguages 2>/dev/null | grep -q '"zh'; then ZH=1; fi
m() { if [ "$ZH" -eq 1 ]; then echo "$1"; else echo "$2"; fi; }

NO_LAUNCH=0
for a in "$@"; do
  case "$a" in
    --no-launch) NO_LAUNCH=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

WORK="$(mktemp -d)"
cleanup() {
  if [ -n "${MOUNT:-}" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

say()  { printf '%s\n' "$1"; }
die()  { printf '\n%s\n' "$1" >&2; exit 1; }

# ---------- 环境检查 ----------
[ "$(uname)" = "Darwin" ] || die "$(m '错误：LidKeep 只支持 macOS。' 'Error: LidKeep is macOS only.')"

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || [ "$ARCH" = "x86_64" ] || \
  die "$(m "错误：不支持的架构 ${ARCH}。" "Error: unsupported architecture ${ARCH}.")"

say "$(m "▸ 正在查找最新版本…" "▸ Looking up the latest version…")"
VERSION="$(curl -fsSL --max-time 12 -A LidKeep \
  "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION="$DEFAULT_VERSION"
say "  $(m "版本 v${VERSION}" "version v${VERSION}")"

DMG="LidKeep-${VERSION}.dmg"

# ---------- 下载（带镜像回退）----------
say "$(m "▸ 正在下载 ${DMG}…" "▸ Downloading ${DMG}…")"
DMG_PATH=""
for base in "${MIRRORS[@]}"; do
  url="${base}/v${VERSION}/${DMG}"
  host="$(printf '%s' "$url" | awk -F/ '{print $3}')"
  printf '  %s… ' "$host"
  tmp="${WORK}/${DMG}"
  : > "$tmp"
  if curl -fsSL --max-time 90 --retry 1 -A LidKeep -o "$tmp" "$url" 2>/dev/null \
     && [ -s "$tmp" ] && [ "$(stat -f%z "$tmp" 2>/dev/null || echo 0)" -gt 500000 ]; then
    printf '%s\n' "$(m '成功' 'ok')"
    DMG_PATH="$tmp"
    break
  fi
  printf '%s\n' "$(m '失败，换下一个' 'failed, trying next')"
  rm -f "$tmp"
done
[ -n "$DMG_PATH" ] || die "$(m \
  '错误：所有下载源都不可用。可以手动从 GitHub Releases 下载。' \
  'Error: every download source failed. Try downloading from GitHub Releases manually.')"

SIZE="$(stat -f%z "$DMG_PATH")"
say "  $(m "已下载 $((SIZE / 1024)) KB" "downloaded $((SIZE / 1024)) KB")"

# ---------- 校验 SHA256 ----------
say "$(m '▸ 正在校验文件完整性…' '▸ Verifying integrity…')"
EXPECT=""
for base in "${MIRRORS[@]}"; do
  EXPECT="$(curl -fsSL --max-time 20 -A LidKeep "${base}/v${VERSION}/SHA256SUMS" 2>/dev/null \
    | awk -v f="$DMG" '$2 == f || $2 == "*"f {print $1}' | head -1)"
  [ -n "$EXPECT" ] && break
done

if [ -n "$EXPECT" ]; then
  ACTUAL="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  if [ "$ACTUAL" = "$EXPECT" ]; then
    say "  ✓ SHA256 $(m '与官方一致' 'matches the published checksum')"
  else
    die "$(m \
      "错误：SHA256 不一致，文件可能已损坏或被篡改，已中止。
  期望 ${EXPECT}
  实际 ${ACTUAL}" \
      "Error: SHA256 mismatch — the file may be corrupt or tampered with. Aborting.
  expected ${EXPECT}
  actual   ${ACTUAL}")"
  fi
else
  say "  ! $(m '取不到官方校验和，跳过（可手动比对）' 'could not fetch the checksum, skipping')"
fi

# ---------- 挂载 ----------
say "$(m '▸ 正在安装…' '▸ Installing…')"
MOUNT="$(hdiutil attach "$DMG_PATH" -nobrowse -plist 2>/dev/null \
  | awk -F'>|<' '/mount-point/{getline; print $3; exit}')"
[ -n "$MOUNT" ] && [ -d "$MOUNT/LidKeep.app" ] || \
  die "$(m '错误：无法挂载磁盘镜像。' 'Error: could not mount the disk image.')"

# 已安装则先退出，避免覆盖正在运行的文件
if [ -d "/Applications/LidKeep.app" ]; then
  pgrep -x LidKeep >/dev/null 2>&1 && osascript -e 'tell application "LidKeep" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/LidKeep.app"
fi

cp -R "$MOUNT/LidKeep.app" /Applications/ || \
  die "$(m '错误：无法写入 /Applications。' 'Error: could not write to /Applications.')"

# ---------- 关键一步：清隔离标记 ----------
# 构建是 ad-hoc 签名、未公证，带隔离标记会被 Gatekeeper 判定为
# 「已损坏」并移进废纸篓。这行是必须的，公证完成后即可移除。
xattr -dr com.apple.quarantine "/Applications/LidKeep.app" 2>/dev/null || true

# ---------- CLI（可选，失败不影响主流程）----------
CLI_DONE=0
if [ -f "$MOUNT/lidkeep" ]; then
  for dest in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
    mkdir -p "$dest" 2>/dev/null || continue
    if cp "$MOUNT/lidkeep" "$dest/lidkeep" 2>/dev/null && chmod +x "$dest/lidkeep" 2>/dev/null; then
      CLI_DONE=1; say "  ✓ CLI → $dest/lidkeep"; break
    fi
  done
  [ "$CLI_DONE" -eq 0 ] && say "  ! $(m 'CLI 未安装（目录不可写），不影响 App 使用' 'CLI not installed (no writable dir); the app works without it')"
fi

# ---------- 完成 ----------
say ""
say "✓ $(m '安装完成' 'Installed')"
say "  $(m 'App：/Applications/LidKeep.app' 'App: /Applications/LidKeep.app')"

if [ "$NO_LAUNCH" -eq 0 ]; then
  say "$(m '▸ 正在启动…' '▸ Launching…')"
  open -a /Applications/LidKeep.app 2>/dev/null || true
  sleep 2
  if pgrep -x LidKeep >/dev/null 2>&1; then
    say "  ✓ $(m '已在菜单栏运行，看屏幕右上角。' 'Running in the menu bar — look at the top right.')"
  else
    say "  ! $(m '没能自动启动，请手动打开 /Applications/LidKeep.app' 'Could not launch automatically; open /Applications/LidKeep.app manually')"
  fi
fi

say ""
say "$(m \
'卸载：跑 LidKeep 菜单里的卸载项，或参考仓库 README。' \
'To uninstall: use the menu item in LidKeep, or see the README.')"
say "  https://github.com/${REPO}"
