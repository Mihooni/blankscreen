# BlankScreen

**Turn the display off without stopping the Mac.**

The screen goes pitch black; the machine keeps working. Remote desktop stays connected, downloads keep going, builds keep running. Press a hotkey (or run one command over SSH) and the picture comes straight back.

[![Release](https://img.shields.io/github/v/release/Mihooni/blankscreen)](../../releases/latest)
[![Platform](https://img.shields.io/badge/macOS-13%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

中文说明: [README.zh-CN.md](README.zh-CN.md)

```
$ blankscreen off      # screen goes black, system keeps running
$ blankscreen on       # display restored (also works over SSH)
```

## Sound familiar?

| # | Situation | What usually happens |
|---|---|---|
| 1 | You want the screen dark to save power, but you're not at the machine | The moment it sleeps, remote desktop connects to a black frame |
| 2 | You close the lid and toss the Mac in a bag | The machine sleeps with it — downloads, builds and remote sessions all drop |
| 3 | You run closed-lid, or carry it closed | The moment sleep is prevented, the built-in panel stays lit — macOS never turns the backlight off just because you closed the lid |
| 4 | You brute-force it with `caffeinate` | The screen glows all night — power drain, burn-in risk, and everything on it is visible to passers-by |
| 5 | You use macOS display sleep | The framebuffer is torn down, screen sharing captures nothing, remote access is effectively dead |

**The core problem:** macOS wires "display off" and "system asleep" together. You only want the screen off; the system puts the whole machine to sleep.

## Why not just use the built-in options

| Method | Screen off | Remote frames | Machine keeps working | Works closed-lid | Permissions |
|---|:---:|:---:|:---:|:---:|---|
| macOS display sleep | ✅ | ❌ lost | ❌ sleeps | — | none |
| `pmset displaysleepnow` | ✅ | ❌ lost | ❌ sleeps | — | none |
| Screensaver / lock screen | ❌ still lit | ✅ | ⚠️ sleeps eventually | — | none |
| `caffeinate` | ❌ stays lit | ✅ | ✅ | ❌ AC power only | none |
| Third-party keep-awake apps | ❌ stays lit | ✅ | ✅ | partial | some need grants |
| **BlankScreen** | ✅ | ✅ | ✅ | ✅ | **hotkey needs none** (lid mode needs a one-time helper) |

One row makes all the difference: **BlankScreen kills the backlight, not the display's power.**
The display never sleeps, so the framebuffer keeps rendering and a remote viewer always sees the real picture instead of a black box.

## The fix: three switches, one job each

| Menu item | What it solves | How to use it |
|---|---|---|
| **关闭显示器** (Turn display off) | Screen goes black instantly, machine keeps running | Click it, or press ⌃⌥⌘B |
| **息屏时不睡眠** (Stay awake while blanked) | The system doesn't follow the screen into sleep | Tick once; applies to every blackout after that |
| **合盖后不睡眠** (Stay awake with the lid closed) | Built-in panel turns off on lid close, machine runs for hours | Tick once; restored automatically after app or system restarts |

They never interfere with each other: the lid daemon and the blackout-linked anti-sleep are separate entries in an internal ledger, so turning one off leaves the other running.

## Up and running in 30 seconds

1. Download `BlankScreen-<version>.dmg` from [Releases](../../releases/latest)
2. Open it and drag the app into Applications
3. Click the ☀ icon in the menu bar → **关闭显示器** (Turn display off)

The screen goes black. Press ⌃⌥⌘B (or click the icon again) to bring it back.
For closed-lid use, tick **合盖后不睡眠（长期运行）** — one admin-password prompt installs a privileged helper, and it keeps working from then on.

## Three ways people actually use it

**A. The Mac as a remote host** (UURemote / ToDesk / VNC / SSH)
`blankscreen off` → screen dark, machine awake, remote picture fine. Press the hotkey when you're back at the desk.
Worried you'll forget? A 12-hour fallback timeout restores the display automatically.

**B. Closed in a bag, still working**
Tick "合盖后不睡眠" → close the lid → **the built-in panel turns itself off** (since v1.5.2, via the SMC lid switch). Downloads, builds and remote sessions keep going; open the lid and brightness is restored.
If the battery drops below the floor while discharging, it stops and notifies you instead of draining to zero.

**C. Stepping away from the desk**
Hit the hotkey; the screen goes dark and your tasks keep running.
⚠️ Blanking is **not** locking — anyone who sits down can still type. Press ⌃⌘Q before you leave.

## How it works

Instead of letting macOS put the display to sleep (which kills the framebuffer and breaks screen capture), BlankScreen sets the **system brightness to 0** and holds a `caffeinate -di` assertion so the display pipeline stays fully powered. Verified behavior:

| Probe | Normal | Blacked out |
|---|---|---|
| Screenshot content | rendered | fully rendered (not painted black) |
| `CGDisplayIsAsleep()` | 0 | **0** — display never sleeps |
| Display power state | 4 (max) | **4** (max) |

The trade-off is deliberate: true display sleep saves ~0.5–1.5 W more, but makes remote frames unavailable. BlankScreen keeps the machine fully remote-controllable.

## Details worth knowing

- **Zero permission grants.** The global hotkey uses the Carbon `RegisterEventHotKey` API, dispatched by WindowServer itself — no Accessibility or Input Monitoring grants, and it keeps working after every rebuild (ad-hoc signed binaries lose TCC grants on each recompile, the most common trap for small tools like this).
- **Crash-safe.** If the app is killed while the screen is black, the next launch restores your previous brightness automatically. A configurable fallback timeout (default 12 h) is the last safety net.
- **Battery guard.** Only on battery and discharging: below the floor (default 20%) a blackout is refused, and during a blackout the level is re-checked every 30 s — cross the floor and the display comes back with a notification. No effect on AC power.
- **CLI and app share state.** `blankscreen on` over SSH can restore a screen the menu bar app turned off, and vice versa.
- **Single instance.** Launching a second copy takes over cleanly and kills orphaned `caffeinate` helpers.

## Requirements

- macOS 13 Ventura or later (built as a universal binary: Apple Silicon + Intel)
- Built-in display (brightness control via DisplayServices; external monitors without DDC support are not affected)

## Install

**Option A — installer (recommended).** Download `BlankScreen-<version>.pkg` from
[Releases](../../releases/latest) and double-click it. One step, both pieces installed:

| Installed to | Item |
|---|---|
| `/Applications/BlankScreenBar.app` | menu bar app |
| `/usr/local/bin/blankscreen` | CLI |

The installer also clears the Gatekeeper quarantine flag and launches the app for you,
so there is nothing to do by hand.

**Option A2 — DMG drag-and-drop.** Download `BlankScreen-<version>.dmg` from
[Releases](../../releases/latest), open it, and drag the app into Applications.
Double-click `安装命令行工具.command` inside the image to also install the CLI
(one GUI password prompt). If Gatekeeper blocks the first launch, right-click
the app → **Open**.

**Option B — build from source** (needs Xcode Command Line Tools):

```bash
git clone https://github.com/Mihooni/blankscreen.git
cd blankscreen
./install.sh              # installs CLI to your Homebrew prefix (/opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel) + app to /Applications
```

`./install.sh --cli-only` skips the menu bar app. `make pkg` builds the same installer locally.

**Option C — download a prebuilt zip** from [Releases](../../releases/latest), then:

```bash
xattr -dr com.apple.quarantine BlankScreenBar.app   # unsigned build: clear Gatekeeper flag
cp -R BlankScreenBar.app /Applications/
# Apple Silicon: sudo cp blankscreen /opt/homebrew/bin/   |   Intel: sudo cp blankscreen /usr/local/bin/
```

> **Not signed with a paid developer certificate.** macOS may refuse to open the
> downloaded `.pkg` ("unidentified developer"). If that happens, right-click the
> `.pkg` → **Open**, then confirm. Same for the app on first launch — though the
> installer already clears its quarantine flag, so the app should open normally
> right after installing.

### Verify a download (optional)

Each release ships a `SHA256SUMS` checksum file plus GitHub build-provenance
attestations (SLSA), so you can confirm the artifacts came from this repo's
workflow — no Apple account needed:

```bash
shasum -a 256 -c SHA256SUMS                                          # bytes match what was published
gh attestation verify blankscreen-macos.zip -R Mihooni/blankscreen   # built by this repo's release workflow
```

## Usage

**Menu bar app** — click ☀ / 🌙 in the menu bar; the three core functions are named in plain words:

- **关闭显示器** — black out now, machine keeps running (click again or press the hotkey to restore)
- **息屏时不睡眠** — while the screen is off, keep the system awake; released automatically on restore
- **合盖后不睡眠（长期运行）** — keep running with the lid closed, restored after a reboot (see [anti-sleep](#anti-sleep-closed-lid--battery--headless))
- 安装提权助手 (Install privileged helper, first run) — extends the two above to battery and closed lid (one password prompt)
- 设置… (Settings) — hotkey combo + key, fallback timeout, battery guard, restore-brightness policy, launch at login
- 热键自检 (Hotkey self-test) — synthesizes your hotkey once and verifies the delivery path (no side effects)
- 打开日志 (Open log)

**CLI**:

```bash
blankscreen off                    # black out now (one-shot daemon, auto-restores after timeout)
blankscreen off --timeout 3600     # custom fallback timeout
blankscreen on                     # restore the display
blankscreen toggle                 # one-command switch — handy for hotkey tools and remote scripts
blankscreen status                 # state, including power source and battery level
blankscreen doctor                 # full self-check: display control, processes, leftovers
blankscreen version                # print version (include it when reporting issues)
blankscreen bright 0.5             # read/write system brightness directly
blankscreen service install        # run the CLI as a launchd service (menu app not required)
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
blankscreen config --battery 20    # battery floor %: refuse/exit blackout below it (0 = off)
blankscreen config --auto-nosleep  # link anti-sleep to blackout; auto-reset on restore
```

Default hotkey: **⌃⌥⌘B**. Change it in the settings panel or via `blankscreen config`. The combo must include at least one modifier (⌘/⌃/⌥/⇧) — macOS rejects global hotkeys without one.

**Multiple displays:** blackout applies to every online display. However, most HDMI/DVI/DP
external monitors don't support software brightness, so those panels can't be dimmed —
`blankscreen doctor` tells you exactly which one, instead of leaving you guessing.

## Anti-sleep (closed lid / battery / headless)

Blackout only kills the backlight — the system itself still sleeps on schedule. If the machine must keep working while blacked out (remote access, downloads, closed-clamshell use), enable anti-sleep:

```bash
blankscreen nosleep setup                  # one command: install helper + blackout linkage + start anti-sleep
blankscreen nosleep on                     # process-level (caffeinate; effective on AC power only)
blankscreen nosleep on --system            # system-level (covers battery + lid; requires the helper)
blankscreen nosleep on --timeout 3600      # auto-stop after a duration
blankscreen nosleep status                 # level / power source / uptime
blankscreen nosleep off                    # stop and reset
```

### Lid-closed anti-sleep (long-running mode)

In the menu bar app, click **"合盖后不睡眠（长期运行）"** to enable with one click — no terminal needed:

- **Closed lid = display off, machine keeps running**: downloads, remote access, external displays and long tasks all keep working
- **Automatic lid blackout (since v1.5.2)**: the daemon polls the SMC lid switch (MSLD key); on lid close it zeroes the built-in display brightness and restores it when the lid opens — the built-in panel only, external displays are never touched; when the daemon stops (battery floor / timeout / manual off) the brightness is restored too, never leaving a black screen behind
- **Persistent**: the flag is saved in config; the daemon is restored automatically after app or system restarts
- **Safety net**: auto-stops with a notification when the battery (discharging) drops below the floor (default 20%); turning it off resets `disablesleep`
- **Independent of blackout linkage**: the lid daemon and blackout-linked anti-sleep are separate entries in the owner ledger, so toggling one never disturbs the other
- Requires the privileged helper; if missing, the menu walks you through the graphical one-click install (one admin-password prompt)

You can also tick "合盖不睡眠（长期模式）" in the settings panel, or use the CLI:

```bash
blankscreen nosleep on --system            # enable directly (helper required)
blankscreen nosleep status                 # shows the lid-mode state
blankscreen nosleep off                    # stop and reset
```

**Why does the system level need a privileged helper?** Per `man caffeinate`, the `-s` assertion is effective **on AC power only**. Covering battery and closed-lid requires `pmset disablesleep`, which must run as root. Install the helper once (asks for your admin password):

```bash
sudo blankscreen nosleep install-helper    # least privilege: sudoers limited to this tool, 4 whitelisted args
blankscreen nosleep detect                 # check disablesleep support on this system
sudo blankscreen nosleep uninstall-helper  # uninstall (resets disablesleep before removal)
```

Safety design:

- The helper is a whitelisted script that only accepts `on` / `off` / `status` / `detect` — it cannot be abused to run arbitrary commands
- sudoers grants a single user, running as root, exactly those four arguments
- Uninstall resets `disablesleep 0` *before* deleting the helper — no "system never sleeps again" leftovers
- A boot-time LaunchDaemon plus a self-heal check on every start reset any state left by a crashed process
- **Owner accounting:** `disablesleep` is a single global switch that "blackout-linked anti-sleep"
  and "manual anti-sleep" may both depend on. The helper records each owner, so when one stops it
  only unregisters itself — it never disables the anti-sleep the other one still relies on.
  (Ledger lives in `/var/db/blankscreen-nosleep`, owned by root; unprivileged users can't forge owners.)
- **Coexists with remote-control apps:** ToDesk / Sunlogin / UURemote / TeamViewer and friends hold the same switch to stay reachable. When one is running, `doctor` reports "held by a remote-control app" instead of flagging it as a leftover to fix.
- The battery floor applies to anti-sleep too — closed lid + battery + no sleep is the fastest way to drain a battery

## Uninstall

```bash
./uninstall.sh           # or: make uninstall
# config/logs (optional): rm -rf ~/Library/Application\ Support/blankscreen
```

## FAQ

**Hotkey doesn't trigger.** Check the ⚠ badge next to the menu bar icon. Three usual causes: the combo is taken by another app (pick another), the combo has no modifier, or the app was just reinstalled (quit and relaunch once). The hotkey itself never needs any permission.

**Does an auto-brightness sensor fight the blackout?** The app re-asserts brightness 0 twice a second, so ambient-light changes won't light the screen up.

**Why not just `pmset displaysleepnow`?** True display sleep tears down the framebuffer — remote viewers get nothing. Many apps (browsers, Electron apps) also hold `NoDisplaySleepAssertion`, which blocks display sleep entirely. Brightness-zeroing works everywhere and is the only method that keeps remote frames flowing.

**Power savings?** Backlight off saves roughly 1–2 W (up to ~15–30% of a lightly loaded machine). The GPU/compositor keep running by design.

**How does the battery guard work?** It only acts when the Mac is on battery and discharging: below the floor (default 20%), starting a blackout is refused; during a blackout the battery is re-checked every 30 s and the display is restored automatically with a notification once the floor is crossed. On AC power it never interferes. Set `blankscreen config --battery 0` (or the settings panel) to disable.

## Development

```bash
make            # build CLI + app into build/
make test       # end-to-end smoke test (arg validation, config round-trip, anti-sleep, asset parity)
make dev-tools  # build debugging helpers into build/dev-tools/
make clean
```

Source layout (Swift requires the top-level file to be named `main.swift`, so each target gets its own directory):

- `Sources/CLI/main.swift` — command-line tool
- `Sources/Bar/main.swift` — menu bar app
- `Sources/Shared/Version.swift` — generated at build time
- `dev-tools/` — helpers plus `smoke.sh`

`make test` skips cases the current environment can't run (e.g. it won't do a real blackout while
the menu bar app is live, since that would interrupt your session). Set `SMOKE_FULL=1` to force it.

## Known limitations

- **Some external displays can't be turned off.** Dimming relies on the software brightness API,
  which most HDMI/DVI/DP monitors don't support, so those panels stay lit during a blackout.
  `blankscreen doctor` names the exact display. Powering them down would require true display
  sleep, which breaks remote frames — this tool deliberately doesn't do that.

- The panel is **not powered down** — this is intentional. Backlight is driven to 0, so
  the framebuffer keeps rendering and screen-sharing / remote-desktop sessions keep
  working. True display sleep would break remote access; see [How it works](#how-it-works).

- **Blackout is not a lock screen.** While blacked out, anyone with physical access to the
  keyboard can still operate the machine — they just can't see it. Lock manually (⌃⌘Q).

## License

[MIT](LICENSE)
