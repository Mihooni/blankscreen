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
- **单实例**：重复启动会干净地接管，并清理遗留的 `caffeinate` 孤儿进程。

## 环境要求

- macOS 13 Ventura 及以上（universal binary，Apple Silicon 与 Intel 均可）
- 内置显示器（走 DisplayServices 控制亮度；不支持 DDC 的外接显示器不受控）

## 安装

**方式 A —— 源码构建**（需 Xcode Command Line Tools）：

```bash
git clone https://github.com/Mihooni/blankscreen.git
cd blankscreen
./install.sh              # CLI 装到 /usr/local/bin，App 装到 /Applications
```

`./install.sh --cli-only` 可只装命令行工具。

**方式 B —— 下载预编译包**：从 [Releases](../../releases) 下载 zip，然后：

```bash
xattr -dr com.apple.quarantine BlankScreenBar.app   # 清除 Gatekeeper 隔离标记
cp -R BlankScreenBar.app /Applications/
sudo cp blankscreen /usr/local/bin/
```

> App 为 ad-hoc 签名（无付费开发者证书）。首次打开：右键 → 打开；或按上面命令清除隔离标记。

## 使用

**菜单栏**：点击 ☀ / 🌙 图标

- 关闭显示器 / 恢复显示
- 设置… —— 热键组合与按键、兜底超时、恢复亮度策略、登录时自动启动
- 热键自检 —— 自动合成一次热键验证整条链路（无副作用，不会开关屏幕）
- 打开日志

**CLI**：

```bash
blankscreen off                    # 立即黑屏（一次性 daemon，超时自动恢复）
blankscreen off --timeout 3600     # 自定义兜底超时
blankscreen on                     # 恢复显示
blankscreen status                 # 查看状态
blankscreen bright 0.5             # 直接读写系统亮度
blankscreen service install        # 以 launchd 服务常驻（不用菜单栏 App 时）
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
```

默认热键 **⌃⌥⌘B**。可在设置面板或 `blankscreen config` 修改。组合必须带至少一个修饰键（⌘/⌃/⌥/⇧）——macOS 不允许无修饰键的全局热键。

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

## 开发

```bash
make            # 构建 CLI + App 到 build/
make dev-tools  # 编译调试小工具到 build/dev-tools/
make clean
```

源码结构：`Sources/blankscreen.swift`（CLI）、`Sources/BlankScreenBar.swift`（菜单栏 App）、`dev-tools/`（开发期用的截帧 / 亮度 / 探测辅助工具）。

## 许可

[MIT](LICENSE)
