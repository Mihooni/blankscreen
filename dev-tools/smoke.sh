#!/bin/bash
# blankscreen 端到端冒烟测试
#
# 目的：把「改了代码还能不能用」从人工验证变成一条命令。
# 覆盖：版本/诊断输出、参数校验、配置往返、电量保护、关屏与恢复、孤儿进程、
#       防睡眠启停、合盖熄屏与恢复（模拟）、提权助手资产一致性。
#
# 用法:
#   ./dev-tools/smoke.sh [CLI 路径]        # 默认 build/blankscreen
#   SMOKE_FULL=1 ./dev-tools/smoke.sh      # 强制跑真实关屏测试
#
# 设计取舍：
#   * 检测到菜单栏 App 正在常驻时，跳过真实关屏测试——那会打断用户当前会话，
#     而且测的是已安装的旧二进制，不是刚构建出来的这份。
#   * 检测不到可用亮度接口（如 CI 的虚拟显示）时同样跳过，而不是记失败。

set -uo pipefail

B="${1:-build/blankscreen}"
CFG="$HOME/Library/Application Support/blankscreen/config.json"
pass=0; fail=0; skip=0

ok()   { echo "  ✅ $1"; pass=$((pass + 1)); }
bad()  { echo "  ❌ $1"; fail=$((fail + 1)); }
skip_() { echo "  ⏭  $1（$2）"; skip=$((skip + 1)); }

if [ ! -x "$B" ]; then
    echo "找不到可执行文件或不可执行: $B（先执行 make）" >&2
    exit 2
fi

echo "blankscreen 冒烟测试 —— $($B version 2>/dev/null | head -1)"
echo

# ---------- 1. 版本与诊断 ----------
echo "【1】版本与诊断"
[ -n "$($B version 2>/dev/null)" ] && ok "version 有输出" || bad "version 无输出"
$B doctor >/tmp/bs_doctor.out 2>&1
grep -q "关屏能力" /tmp/bs_doctor.out && ok "doctor 输出完整报告" || bad "doctor 输出异常"

# 依据 doctor 判断环境能力，后面的用例据此决定跑还是跳
no_display=0
grep -q "亮度接口不可用" /tmp/bs_doctor.out && no_display=1
has_service=0
grep -q "常驻服务运行中" /tmp/bs_doctor.out && has_service=1

# ---------- 2. 参数校验 ----------
echo
echo "【2】参数校验（非法输入必须被拒绝，而不是被静默接受）"
reject() {   # $1=描述  $2..=命令
    local d="$1"; shift
    "$@" >/dev/null 2>&1
    [ $? -ne 0 ] && ok "拒绝 $d" || bad "接受了非法输入：$d"
}
reject "越界亮度 5"            "$B" bright 5
reject "非数值亮度 abc"         "$B" bright abc
reject "越界电量 200"          "$B" config --battery 200
reject "越界键码 999"          "$B" config --key 999
reject "负数超时 -1"           "$B" config --timeout -1
reject "非法恢复策略 abc"       "$B" config --restore abc
reject "无修饰键热键"          "$B" config --mods "" --key 0

# ---------- 3. 配置往返 ----------
echo
echo "【3】配置读写往返"
$B config >/dev/null 2>&1
# 压缩掉空白再取字段：App 保存的是 pretty-printed JSON（"batteryFloor" : 20），
# CLI 保存的是紧凑格式，两种都要能解析
json_batt() { [ -f "$CFG" ] || return 0; tr -d ' \n\t' < "$CFG" 2>/dev/null | grep -o '"batteryFloor":[0-9]*' | grep -o '[0-9]*$'; }
orig=$(json_batt); orig=${orig:-20}
$B config --battery 35 >/dev/null 2>&1
now=$(json_batt)
[ "${now:-}" = "35" ] && ok "写入配置已落盘（电量下限 35）" || bad "配置未生效（读到 ${now:-空}）"
$B config --battery "$orig" >/dev/null 2>&1
back=$(json_batt)
[ "${back:-}" = "$orig" ] && ok "配置已复原（${orig}）" || bad "配置未能复原（读到 ${back:-空}）"

# ---------- 4. 电量保护 ----------
echo
echo "【4】电量保护（模拟电池 10% 放电中）"
if [ "$has_service" -eq 1 ]; then
    skip_ "低电量拒绝关屏" "常驻服务由另一进程持有，环境变量无法注入"
elif [ "$no_display" -eq 1 ]; then
    skip_ "低电量拒绝关屏" "无可用亮度接口"
else
    BS_SIMULATE_BATTERY="10,batt,discharging" "$B" off >/dev/null 2>&1
    [ $? -ne 0 ] && ok "低电量时拒绝关屏并报错" || bad "低电量未拒绝关屏"
fi

# ---------- 5. 关屏与恢复 ----------
echo
echo "【5】关屏与恢复（会短暂黑屏）"
if [ "$no_display" -eq 1 ]; then
    skip_ "关屏 / 恢复" "无可用亮度接口"
elif [ "$has_service" -eq 1 ]; then
    skip_ "关屏 / 恢复" "菜单栏 App 常驻中，避免打断当前会话"
elif [ "${SMOKE_FULL:-0}" != "1" ]; then
    skip_ "关屏 / 恢复" "默认跳过，设 SMOKE_FULL=1 启用"
else
    before=$("$B" bright 2>/dev/null | awk '{print $NF}')
    "$B" off >/dev/null 2>&1
    sleep 1.2
    mid=$("$B" bright 2>/dev/null | awk '{print $NF}')
    [ "$mid" = "0.0" ] && ok "关屏后亮度为 0" || bad "关屏后亮度=$mid"
    "$B" on >/dev/null 2>&1
    sleep 1.2
    after=$("$B" bright 2>/dev/null | awk '{print $NF}')
    same=$(awk -v a="$before" -v b="$after" 'BEGIN{d=a-b; if(d<0)d=-d; print (d<0.02)?"1":"0"}')
    [ "$same" = "1" ] && ok "恢复后亮度回到原值（${before} → ${after}）" \
                       || bad "恢复后亮度偏差过大（${before} → ${after}）"
fi

# ---------- 6. 残留进程 ----------
echo
echo "【6】残留进程"
if grep -q "无孤儿 caffeinate" /tmp/bs_doctor.out; then
    ok "无孤儿 caffeinate"
else
    bad "存在孤儿 caffeinate：$(grep '孤儿\|caffeinate pid' /tmp/bs_doctor.out | head -2 | tr '\n' ' ')"
fi

# ---------- 7. 防睡眠启停 ----------
echo
echo "【7】防睡眠启停与超时自停"
"$B" nosleep off >/dev/null 2>&1
"$B" nosleep on --timeout 2 >/dev/null 2>&1
sleep 0.6
if "$B" nosleep status 2>/dev/null | grep -q "已开启"; then
    ok "防睡眠已开启"
else
    bad "防睡眠未能开启"
fi
sleep 2.6
if "$B" nosleep status 2>/dev/null | grep -q "未开启"; then
    ok "超时后自动停止"
else
    bad "超时后未自动停止"
fi

# ---------- 8. 合盖熄屏与恢复（模拟合盖，不依赖物理开合盖子） ----------
echo
echo "【8】合盖熄屏与恢复（BS_SIMULATE_LID_CLOSED 模拟）"
log_file="$HOME/Library/Application Support/blankscreen/blankscreen.log"
log_tail() {  # 打印自调用前累积行数之后的新日志
    local n0="$1"
    tail -n "+$((n0 + 1))" "$log_file" 2>/dev/null
}
if [ "$no_display" -eq 1 ]; then
    skip_ "合盖熄屏" "无可用亮度接口"
elif [ "$has_service" -eq 1 ]; then
    skip_ "合盖熄屏" "菜单栏 App 常驻中，避免熄灭用户屏幕"
else
    "$B" nosleep off >/dev/null 2>&1
    n0=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    # --timeout 8 兜底：即使断言失败守护也会自停，不留黑屏
    BS_SIMULATE_LID_CLOSED=1 "$B" nosleep on --timeout 8 >/dev/null 2>&1
    sleep 3
    if log_tail "$n0" | grep -q "内屏已熄灭"; then
        ok "合盖后内屏自动熄灭"
    else
        bad "合盖后未见熄屏记录（日志: $(log_tail "$n0" | grep '^lid' | tail -1)）"
    fi
    mid=$("$B" bright 2>/dev/null | awk '{print $NF}')
    [ "$mid" = "0.0" ] && ok "合盖期间内屏亮度为 0" || bad "合盖期间亮度=$mid"
    # 守护退出（此处为超时自停）必须恢复亮度——不留黑屏残局
    sleep 7
    if log_tail "$n0" | grep -q "恢复内屏亮度"; then
        ok "守护停止时恢复内屏亮度"
    else
        bad "守护停止时未见恢复记录"
    fi
    after=$("$B" bright 2>/dev/null | awk '{print $NF}')
    [ "$(awk -v a="$after" 'BEGIN{print (a>0.05)?"1":"0"}')" = "1" ] \
        && ok "停止后内屏亮度已恢复（$after）" || bad "停止后内屏仍黑着（$after）"
fi

# ---------- 9. 提权助手资产一致性 ----------
echo
echo "【9】提权助手资产一致性（内嵌资产必须与仓库副本逐字相同）"
tmp_assets=$(mktemp -d)
"$B" nosleep write-assets "$tmp_assets" >/dev/null 2>&1
if diff -q "$tmp_assets/com.blankscreen.pmset" packaging/helper/com.blankscreen.pmset >/dev/null 2>&1; then
    ok "helper 脚本与仓库副本一致"
else
    bad "helper 脚本与仓库副本不一致（执行 make 后重新 write-assets 同步）"
fi
if diff -q "$tmp_assets/com.blankscreen.nosleep.reset.plist" \
            packaging/helper/com.blankscreen.nosleep.reset.plist >/dev/null 2>&1; then
    ok "开机复位 LaunchDaemon 与仓库副本一致"
else
    bad "LaunchDaemon 与仓库副本不一致"
fi
# 提权脚本必须能被 shell 解析：它会被 root 执行，语法错误意味着安装即损坏
if sh -n packaging/helper/com.blankscreen.pmset 2>/dev/null; then
    ok "helper 脚本语法正确"
else
    bad "helper 脚本存在语法错误"
fi
rm -rf "$tmp_assets"

# ---------- 汇总 ----------
echo
echo "———— 结果：通过 ${pass}，失败 ${fail}，跳过 ${skip} ————"
[ "$fail" -eq 0 ] || exit 1
exit 0
