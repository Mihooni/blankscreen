# BlankScreen

**关屏但不睡眠** —— 显示器熄灭，系统保持唤醒，远程桌面 / 屏幕共享照常抓帧。按全局热键（或远程执行一条命令）即可恢复显示。适合把 Mac 当远程主机用的场景。

English documentation: [README.md](README.md)

```
$ blankscreen off     # 屏幕熄灭，系统继续运行
$ blankscreen on      # 恢复显示（SSH 远程执行同样有效）
```

## 工作原理

不用 macOS 的「显示器睡眠」（那会停掉帧缓冲，远程就看不到画面了），而是把**系统亮度归零**，同时用 `caffeinate -di` 持有断言，保证显示管线满功率运行。实测：

| 检测项 | 正常显示 | 黑屏时 |
|---|---|---|
| 截帧内容 | 正常渲染 | 完整渲染（不是涂黑） |
| `CGDisplayIsAsleep()` | 0 | **0**（显示器从未睡眠） |
| 显示控制器电源状态 | 4（满功率） | **4**（满功率） |

代价是刻意选择的：真·显示器睡眠能多省约 0.5–1.5 W，但远程画面就没了。BlankScreen 保证机器始终可被远程操控。

## 特性

- **零权限**。全局热键走 Carbon `RegisterEventHotKey`，由 WindowServer 直接派发——不需要「辅助功能」「输入监控」任何授权，而且反复重编译、重装都不会失效（ad-hoc 签名二进制走 TCC 授权会在每次重编译后失效，这是同类小工具最常见的坑）。
- **菜单栏 App**（`BlankScreenBar.app`）：点击图标开关显示器；设置面板支持自定义热键、兜底超时、恢复亮度策略、开机自启；内置热键自检；日志查看。
- **CLI**（`blankscreen`）：`off` / `on` / `status` / `bright` / `config`，可在 SSH 里直接用；CLI 与菜单栏 App 状态互通，谁都能开关。
- **崩溃安全**：黑屏期间进程被意外杀死，下次启动会自动恢复原亮度；还有可配置的兜底超时（默认 12 小时）作为最后的安全网。
- **电量保护**：仅使用电池（且在放电）时，电量低于下限（默认 20%）会拒绝关屏；黑屏期间跌破下限则自动恢复显示并通知——忘了恢复的黑屏不会再耗尽电池。插着电源时不干预。
- **单实例**：重复启动会干净地接管，并清理遗留的 `caffeinate` 孤儿进程。

## 环境要求

- macOS 13 Ventura 及以上（universal binary，Apple Silicon 与 Intel 均可）
- 内置显示器（走 DisplayServices 控制亮度；不支持 DDC 的外接显示器不受控）

## 安装

**方式 A —— 安装包（推荐）**：从 [Releases](../../releases) 下载
`BlankScreen-<版本号>.pkg`，双击即可，一步装好两项：

| 安装位置 | 内容 |
|---|---|
| `/Applications/BlankScreenBar.app` | 菜单栏 App |
| `/usr/local/bin/blankscreen` | 命令行工具 |

安装器会自动清除 Gatekeeper 隔离标记并启动 App，无需任何手工操作。

**方式 B —— 源码构建**（需 Xcode Command Line Tools）：

```bash
git clone https://github.com/Mihooni/blankscreen.git
cd blankscreen
./install.sh              # CLI 装到 Homebrew 前缀（Apple 芯片 /opt/homebrew/bin，Intel /usr/local/bin），App 装到 /Applications
```

`./install.sh --cli-only` 可只装命令行工具。`make pkg` 可在本地生成同样的安装包。

**方式 C —— 下载预编译包**：从 [Releases](../../releases) 下载 zip，然后：

```bash
xattr -dr com.apple.quarantine BlankScreenBar.app   # 清除 Gatekeeper 隔离标记
cp -R BlankScreenBar.app /Applications/
# Apple 芯片: sudo cp blankscreen /opt/homebrew/bin/   |   Intel: sudo cp blankscreen /usr/local/bin/
```

> **未使用付费开发者证书签名。** macOS 可能拒绝打开下载来的 `.pkg`（提示"身份不明的开发者"）。
> 此时对 `.pkg` 右键 → **打开**，再确认即可。App 首次启动同理——不过安装器已自动清除了
> App 的隔离标记，装完直接就能正常打开。

### 验证下载（可选）

每个 Release 都附带 `SHA256SUMS` 校验和文件与 GitHub 构建来源证明（SLSA attestation），
无需任何 Apple 账号即可确认产物确实出自本仓库的构建流程：

```bash
shasum -a 256 -c SHA256SUMS                                          # 校验文件完整性
gh attestation verify blankscreen-macos.zip -R Mihooni/blankscreen   # 验证构建来源
```

## 使用

**菜单栏**：点击 ☀ / 🌙 图标

- 关闭显示器 / 恢复显示
- 防睡眠 —— 黑屏 / 合盖期间阻止系统睡眠（见[防睡眠](#防睡眠合盖--电池--无显示器时不睡眠)）
- 设置… —— 热键组合与按键、兜底超时、电量保护、恢复亮度策略、登录时自动启动
- 热键自检 —— 自动合成一次热键验证整条链路（无副作用，不会开关屏幕）
- 打开日志

**CLI**：

```bash
blankscreen off                    # 立即黑屏（一次性 daemon，超时自动恢复）
blankscreen off --timeout 3600     # 自定义兜底超时
blankscreen on                     # 恢复显示
blankscreen status                 # 查看状态（含电源与电量）
blankscreen bright 0.5             # 直接读写系统亮度
blankscreen service install        # 以 launchd 服务常驻（不用菜单栏 App 时）
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
blankscreen config --battery 20    # 电量下限 %：低于则拒绝/退出黑屏（0 = 不限制）
blankscreen config --auto-nosleep  # 关屏时自动联动防睡眠，恢复显示时自动复位
```

默认热键 **⌃⌥⌘B**。可在设置面板或 `blankscreen config` 修改。组合必须带至少一个修饰键（⌘/⌃/⌥/⇧）——macOS 不允许无修饰键的全局热键。

## 防睡眠（合盖 / 电池 / 无显示器时不睡眠）

黑屏只关背光，系统本身仍会按设置睡眠。如果需要黑屏期间机器持续工作（远程访问、下载、合盖外接使用），可以开启防睡眠：

```bash
blankscreen nosleep setup                  # 一键到位：装助手 + 开关屏联动 + 立即防睡眠
blankscreen nosleep on                     # 进程级（caffeinate，仅接电源时有效）
blankscreen nosleep on --system            # 系统级（覆盖电池与合盖，需先装提权助手）
blankscreen nosleep on --timeout 3600      # 定时自动停止
blankscreen nosleep status                 # 查看层级 / 电源 / 已持续时间
blankscreen nosleep off                    # 停止并复位
```

菜单栏 App 同样提供「一键防睡眠」入口（助手未安装时显示）。

**为什么系统级需要提权助手？** `caffeinate -s` 的断言按 man page 明写「仅 AC 电源有效」；要覆盖电池与合盖，只能调用 `pmset disablesleep`，而它必须以 root 运行。安装助手（一次性，需输入管理员密码）：

```bash
sudo blankscreen nosleep install-helper    # 最小权限：sudoers 限定仅本工具、仅四个白名单参数
blankscreen nosleep detect                 # 查看当前系统对 disablesleep 的支持情况
sudo blankscreen nosleep uninstall-helper  # 卸载（先复位再删除）
```

安全设计：

- 助手是参数白名单脚本，只能执行 `on` / `off` / `status` / `detect`，无法被借道执行任意命令
- sudoers 仅授权单用户、以 root 身份、精确匹配四个参数
- 卸载时先复位 `disablesleep 0` 再删助手，杜绝「系统永不睡眠」残留
- 开机 LaunchDaemon + 每次启动的自愈检查双保险：任何异常退出都会自动复位
- 电量下限对防睡眠同样生效——合盖 + 电池 + 不睡眠是最容易耗尽电池的组合

## 卸载

```bash
./uninstall.sh           # 或: make uninstall
# 配置与日志（可选）: rm -rf ~/Library/Application\ Support/blankscreen
```

## 常见问题

**热键没反应？** 看菜单栏图标旁的 ⚠。三种常见原因：组合被其他 App 占用（换一个）、组合没带修饰键、App 刚重装（退出重开一次）。热键本身永远不需要任何授权。

**环境光自动亮度会干扰黑屏吗？** 不会。程序每 0.5 秒重设一次亮度 0，环境光变化压不住。

**为什么不用 `pmset displaysleepnow`？** 真·显示器睡眠会拆掉帧缓冲，远程端什么都看不到；而且很多 App（浏览器、Electron 应用）持有 `NoDisplaySleepAssertion`，根本进不了显示器睡眠。亮度归零在任何情况下都有效，且是唯一保持远程画面可用的方法。

**省多少电？** 背光关闭约省 1–2 W（轻载整机约 15–30%）。GPU / 合成器仍在工作，这是「远程可控」的必要代价。

**电量保护是怎么工作的？** 仅在「使用电池且正在放电」时生效：电量低于下限（默认 20%）会拒绝进入黑屏；黑屏期间每 30 秒复查一次，跌破下限立即恢复显示并发系统通知。插着电源时完全不干预。可在设置面板或 `blankscreen config --battery 0` 关闭。

## 开发

```bash
make            # 构建 CLI + App 到 build/
make dev-tools  # 编译调试小工具到 build/dev-tools/
make clean
```

源码结构：`Sources/blankscreen.swift`（CLI）、`Sources/BlankScreenBar.swift`（菜单栏 App）、`dev-tools/`（开发期用的截帧 / 亮度 / 探测辅助工具）。

## 已知限制

- **外接显示器不会一起变暗。** 亮度只作用于主显示器（`CGMainDisplayID`）。接了外接屏时，
  内置屏会变黑而外接屏仍正常显示。要覆盖所有屏幕需依赖 DDC/CI，而 Apple 芯片上这条路不可靠。

- 屏幕**并非断电**——这是刻意设计。背光被设为 0，帧缓冲仍在渲染，因此屏幕共享 / 远程桌面
  仍能正常取帧。真正的显示器休眠会中断远程访问，详见[工作原理](#工作原理)。

## 许可

[MIT](LICENSE)
