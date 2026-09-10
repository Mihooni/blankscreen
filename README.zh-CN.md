# BlankScreen

**让 Mac 熄屏，但别停下。**

屏幕全黑，机器照常运行：远程桌面还在、下载还在、构建还在。按一下热键（或 SSH 里一条命令）立刻恢复画面。

[![Release](https://img.shields.io/github/v/release/Mihooni/blankscreen)](../../releases/latest)
[![Platform](https://img.shields.io/badge/macOS-13%2B-blue)](#环境要求)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

English: [README.md](README.md)

```
$ blankscreen off      # 屏幕熄灭，系统继续跑
$ blankscreen on       # 恢复显示（SSH 里执行同样有效）
```

## 你是不是也遇到过这些

| # | 场景 | 通常的结果 |
|---|---|---|
| 1 | 想让屏幕黑掉省电，但人不在机器旁边 | 一熄屏远程就瞎了：系统或显示器进入睡眠后，远程桌面连上只有一片黑 |
| 2 | 合上盖子塞进包里带走 | 机器跟着睡了 —— 下载中断、构建中断、远控掉线 |
| 3 | 合盖接外接显示器 / 合盖带走 | 一旦阻止了睡眠，内屏就一直亮着 —— macOS 不会因为你合上盖子就关背光，纯白耗电 |
| 4 | 用 `caffeinate` / 防睡眠工具硬扛 | 屏幕整夜亮着：费电、烧屏、内容还被别人看见 |
| 5 | 用系统自带的「显示器睡眠」 | 帧缓冲被拆掉，屏幕共享抓不到画面，远程等于断线 |

**本质矛盾**：macOS 把「屏幕灭」和「机器睡」绑在了一起。你想要的只是灭屏幕，系统却连机器一起睡过去了。

## 为什么不直接用系统自带的

| 方式 | 屏幕灭 | 远程画面 | 机器继续跑 | 合盖可用 | 需要权限 |
|---|:---:|:---:|:---:|:---:|---|
| 系统「显示器睡眠」 | ✅ | ❌ 断开 | ❌ 会睡 | — | 无 |
| `pmset displaysleepnow` | ✅ | ❌ 断开 | ❌ 会睡 | — | 无 |
| 屏保 / 锁屏 | ❌ 还亮 | ✅ | ⚠️ 到点会睡 | — | 无 |
| `caffeinate` | ❌ 一直亮 | ✅ | ✅ | ❌ 仅插电有效 | 无 |
| 第三方防睡眠 App | ❌ 一直亮 | ✅ | ✅ | 部分支持 | 部分要授权 |
| **BlankScreen** | ✅ | ✅ | ✅ | ✅ | **热键零授权**（合盖需装一次助手） |

差别只有一行，但决定了能不能用：**BlankScreen 灭的是背光，不是显示器电源**。
显示器从未睡眠，帧缓冲一直在渲染，所以远程端抓到的永远是真实画面，而不是一片黑。

## 解决方案：三个开关，各管一件事

| 菜单项 | 解决什么 | 怎么用 |
|---|---|---|
| **关闭显示器** | 屏幕立刻黑掉，机器照常运行 | 点一下，或按 ⌃⌥⌘B |
| **息屏时不睡眠** | 关屏期间系统不跟着睡 | 勾一次，之后每次关屏自动生效 |
| **合盖后不睡眠（长期运行）** | 合盖后内屏自动熄灭、机器长期运转 | 勾一次，App / 系统重启后自动恢复 |

三者互不干扰：合盖守护和关屏联动在内部账本里是两条独立记录，关掉一个不会影响另一个。

## 30 秒上手

1. 从 [Releases](../../releases/latest) 下载 `BlankScreen-<版本>.dmg`
2. 打开，把 App 拖进 Applications
3. 点菜单栏的 ☀ 图标 → **关闭显示器**

屏幕立刻全黑，按 ⌃⌥⌘B（或再点图标）恢复。
要合盖长期运行，就勾 **合盖后不睡眠（长期运行）** —— 会弹一次系统密码框安装提权助手，装完永久有效。

## 三种典型用法

**A. 把 Mac 当远程主机**（UURemote / ToDesk / VNC / SSH）
`blankscreen off` 熄屏 → 机器不睡 → 远程画面正常。回到机器前按热键恢复。
怕忘？默认 12 小时兜底自动恢复。

**B. 合盖收纳，任务不断**
勾上「合盖后不睡眠」→ 合盖 → **内屏自动熄灭**（v1.5.2 起，经 SMC 检测合盖状态），下载 / 构建 / 远程照常，开盖自动恢复亮度。
电池放电跌破下限会自动停止并通知，不会把电耗光。

**C. 人离开工位，不想屏幕被人看见**
按热键熄屏，任务继续跑。
⚠️ 熄屏 **不等于** 锁屏 —— 别人坐下来敲键盘照样能操作，只是看不见。离开前请手动 ⌃⌘Q。

## 它是怎么做到的

不用 macOS 的「显示器睡眠」（那会停掉帧缓冲，远程就看不到画面了），而是把**系统亮度归零**，
同时用 `caffeinate -di` 持有断言，保证显示管线满功率运行。实测：

| 检测项 | 正常显示 | 黑屏时 |
|---|---|---|
| 截帧内容 | 正常渲染 | 完整渲染（不是涂黑） |
| `CGDisplayIsAsleep()` | 0 | **0**（显示器从未睡眠） |
| 显示控制器电源状态 | 4（满功率） | **4**（满功率） |

代价是刻意选择的：真·显示器睡眠能多省约 0.5–1.5 W，但远程画面就没了。BlankScreen 保证机器始终可被远程操控。

## 还有这些细节

- **零授权热键**。全局热键走 Carbon `RegisterEventHotKey`，由 WindowServer 直接派发 —— 不需要「辅助功能」「输入监控」任何授权，反复重编译、重装也不会失效（ad-hoc 签名二进制每次重编译都会丢 TCC 授权，这是同类小工具最常见的坑）。
- **崩溃安全**。黑屏期间进程被意外杀死，下次启动自动恢复原亮度；另有可配置的兜底超时（默认 12 小时）作为最后安全网。
- **电量保护**。仅电池且放电时生效：低于下限（默认 20%）拒绝关屏，黑屏期间每 30 秒复查，跌破立即恢复并通知。插电不干预。
- **CLI 与 App 状态互通**。SSH 里 `blankscreen on` 能唤醒菜单栏 App 关掉的屏幕，反之亦然。
- **单实例**。重复启动会干净接管，并清理遗留的 `caffeinate` 孤儿进程。

## 界面语言

**跟随系统**：系统语言为中文 → 中文界面；其余语言（含英文）→ 英文界面。菜单栏 App 与命令行工具一致，无需任何设置。

需要临时或固定切换时：

| 方式 | 用法 |
|---|---|
| 环境变量 | `BLANKSCREEN_LANG=en blankscreen doctor`（`zh` / `en`） |
| 配置文件 | `~/Library/Application Support/blankscreen/config.json` 里设 `"lang": "en"` |

配置文件可选 `auto`（跟随系统，默认）/ `zh` / `en`；环境变量优先级最高。

英文界面下三个开关对应：**Turn Display Off** / **Stay Awake While Blanked** / **Stay Awake with Lid Closed**。

## 环境要求

- macOS 13 Ventura 及以上（universal binary，Apple Silicon 与 Intel 均可）
- 内置显示器（走 DisplayServices 控制亮度；不支持 DDC 的外接显示器不受控）

## 安装

**方式 A —— 安装包（推荐）**：从 [Releases](../../releases/latest) 下载
`BlankScreen-<版本号>.pkg`，双击即可，一步装好两项：

| 安装位置 | 内容 |
|---|---|
| `/Applications/BlankScreenBar.app` | 菜单栏 App |
| `/usr/local/bin/blankscreen` | 命令行工具 |

安装器会自动清除 Gatekeeper 隔离标记并启动 App，无需任何手工操作。

**方式 A2 —— DMG 拖拽安装**：从 [Releases](../../releases/latest) 下载
`BlankScreen-<版本号>.dmg`，打开后把 App 拖进 Applications 文件夹；
双击镜像里的「Install Command-Line Tool.command」可顺手装好 CLI（弹一次系统密码框）。
若 App 首次打开被 Gatekeeper 拦下，右键 → **打开** 即可。

**方式 B —— 源码构建**（需 Xcode Command Line Tools）：

```bash
git clone https://github.com/Mihooni/blankscreen.git
cd blankscreen
./install.sh              # CLI 装到 Homebrew 前缀（Apple 芯片 /opt/homebrew/bin，Intel /usr/local/bin），App 装到 /Applications
```

`./install.sh --cli-only` 可只装命令行工具。`make pkg` 可在本地生成同样的安装包。

**方式 C —— 下载预编译包**：从 [Releases](../../releases/latest) 下载 zip，然后：

```bash
xattr -dr com.apple.quarantine BlankScreenBar.app   # 清除 Gatekeeper 隔离标记
cp -R BlankScreenBar.app /Applications/
# Apple 芯片: sudo cp blankscreen /opt/homebrew/bin/   |   Intel: sudo cp blankscreen /usr/local/bin/
```

> **未使用付费开发者证书签名。** macOS 可能拒绝打开下载来的 `.pkg`（提示"身份不明的开发者"）。
> 此时对 `.pkg` 右键 → **打开**，再确认即可。App 首次启动同理 —— 不过安装器已自动清除了
> App 的隔离标记，装完直接就能正常打开。

### 验证下载（可选）

每个 Release 都附带 `SHA256SUMS` 校验和文件与 GitHub 构建来源证明（SLSA attestation），
无需任何 Apple 账号即可确认产物确实出自本仓库的构建流程：

```bash
shasum -a 256 -c SHA256SUMS                                          # 校验文件完整性
gh attestation verify blankscreen-macos.zip -R Mihooni/blankscreen   # 验证构建来源
```

## 使用

**菜单栏**：点击 ☀ / 🌙 图标，三个核心功能一目了然

- **关闭显示器** —— 立即熄屏，机器保持运行（再点一次或按热键恢复）
- **息屏时不睡眠** —— 开启后，每次息屏/关屏期间自动阻止系统睡眠，恢复显示自动解除
- **合盖后不睡眠（长期运行）** —— 合盖也持续运行，重启电脑后自动恢复（见[防睡眠](#防睡眠合盖--电池--无显示器时不睡眠)）
- 安装提权助手（首次使用）… —— 让上面两项覆盖电池与合盖（弹一次系统密码框）
- 设置… —— 热键组合与按键、兜底超时、电量保护、恢复亮度策略、登录时自动启动
- 热键自检 —— 自动合成一次热键验证整条链路（无副作用，不会开关屏幕）
- 打开日志

**CLI**：

```bash
blankscreen off                    # 立即黑屏（一次性 daemon，超时自动恢复）
blankscreen off --timeout 3600     # 自定义兜底超时
blankscreen on                     # 恢复显示
blankscreen toggle                 # 一条命令切换（可绑定到快捷键工具 / 远程脚本）
blankscreen status                 # 查看状态（含电源与电量）
blankscreen doctor                 # 综合自检：关屏能力、显示器可控性、进程、残留
blankscreen version                # 查看版本（反馈问题时一并附上）
blankscreen bright 0.5             # 直接读写系统亮度
blankscreen service install        # 以 launchd 服务常驻（不用菜单栏 App 时）
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
blankscreen config --battery 20    # 电量下限 %：低于则拒绝/退出黑屏（0 = 不限制）
blankscreen config --auto-nosleep  # 关屏时自动联动防睡眠，恢复显示时自动复位
```

默认热键 **⌃⌥⌘B**。可在设置面板或 `blankscreen config` 修改。组合必须带至少一个修饰键（⌘/⌃/⌥/⇧）—— macOS 不允许无修饰键的全局热键。

**多显示器**：关屏会对所有在线显示器生效。但多数 HDMI / DVI / DP 外接屏不支持软件亮度控制，这类屏幕关不掉 —— `blankscreen doctor` 会明确列出哪块屏不可控，不会让你以为它坏了。

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

### 合盖不睡眠（长期模式）

点菜单栏 **「合盖后不睡眠（长期运行）」** 即可一键开启 —— 无需任何终端命令：

- **合盖后内屏熄灭、机器持续运行**：下载、远程访问、外接显示、长时间任务照常工作
- **合盖自动熄屏（v1.5.2 起）**：守护进程经 SMC 检测合盖状态（MSLD 键），合盖时自动把内屏亮度归零，开盖自动恢复；只动内屏，外接显示器不受影响；守护停止（电量下限 / 超时 / 手动关闭）时同样恢复，不留黑屏残局
- **持久化**：标志写入配置，App 重启 / 电脑重启后自动恢复守护
- **安全网**：电池放电低于电量下限（默认 20%）自动停止并通知；关闭即复位 `disablesleep`
- **与关屏联动互不干扰**：合盖守护与黑屏联动防睡眠在持有者账本中是独立条目，各自开关互不影响
- 需要提权助手；未安装时菜单会引导图形化一键安装（弹一次系统密码框）

也可以在设置面板勾选「合盖不睡眠（长期模式，重启自动恢复）」，或用命令行：

```bash
blankscreen nosleep on --system            # 直接开启（需已装提权助手）
blankscreen nosleep status                 # 查看「合盖模式」状态
blankscreen nosleep off                    # 关闭并复位
```

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
- **持有者记账**：`disablesleep` 是唯一的全局开关，而「关屏联动」和「手动防睡眠」可能同时依赖它。助手会记录每个持有者，任一方停止时只注销自己 —— 不会顺手关掉别人正在用的防睡眠。（记账目录为 `/var/db/blankscreen-nosleep`，root 拥有，普通用户无法伪造持有者）
- **与远控软件共存**：ToDesk / Sunlogin / UURemote / TeamViewer 等远控会用同一个开关保持在线。检测到它们在运行时，`doctor` 会说明「由远控软件持有」，而不是误报成需要修复的残留。
- 电量下限对防睡眠同样生效 —— 合盖 + 电池 + 不睡眠是最容易耗尽电池的组合

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
make test       # 端到端冒烟测试（参数校验 / 配置往返 / 防睡眠 / 资产一致性）
make dev-tools  # 编译调试小工具到 build/dev-tools/
make clean
```

源码结构（Swift 要求主文件名为 `main.swift`，因此按 target 分目录）：

- `Sources/CLI/main.swift` —— 命令行工具
- `Sources/Bar/main.swift` —— 菜单栏 App
- `Sources/Shared/Version.swift` —— 构建时生成的版本常量
- `dev-tools/` —— 开发期辅助工具，以及 `smoke.sh` 冒烟测试

`make test` 会自动跳过当前环境跑不了的用例（例如菜单栏 App 正在常驻时不做真实关屏，避免打断会话）；设 `SMOKE_FULL=1` 可强制跑真实关屏 / 恢复。

## 已知限制

- **部分外接显示器关不掉。** 亮度归零依赖软件亮度接口，多数 HDMI / DVI / DP 外接屏不支持它，这类屏幕在关屏时不会熄灭（`blankscreen doctor` 会具体指出是哪一块）。要让它们也熄灭只能走硬件睡眠，而那会中断远程画面 —— 本工具刻意不这么做。
- 屏幕**并非断电** —— 这是刻意设计。背光被设为 0，帧缓冲仍在渲染，因此屏幕共享 / 远程桌面仍能正常取帧。真正的显示器休眠会中断远程访问，详见[它是怎么做到的](#它是怎么做到的)。
- **关屏不等于锁屏。** 关屏期间任何能碰到键盘鼠标的人仍可操作这台机器，只是看不见画面。离开座位前请手动锁屏（⌃⌘Q）。

## 许可

[MIT](LICENSE)
