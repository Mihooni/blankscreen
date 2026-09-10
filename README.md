# BlankScreen

**Turn the display off without putting the Mac to sleep.** Perfect for remote access: the screen goes dark, the system stays awake, and remote desktop / screen sharing keeps working. Press a global hotkey (or run one command over SSH) to bring the display back.

中文说明见 [README.zh-CN.md](README.zh-CN.md)

```
$ blankscreen off     # screen goes black, system keeps running
$ blankscreen on      # display restored (also via SSH)
```

## How it works

Instead of letting macOS put the display to sleep (which kills the framebuffer and breaks screen capture), BlankScreen sets the **system brightness to 0** and holds a `caffeinate -di` assertion so the display pipeline stays fully powered. Verified behavior:

| Probe | Normal | Blacked out |
|---|---|---|
| Screenshot content | rendered | fully rendered (not painted black) |
| `CGDisplayIsAsleep()` | 0 | **0** — display never sleeps |
| Display power state | 4 (max) | **4** (max) |

The trade-off is deliberate: true display sleep saves ~0.5–1.5 W more, but makes remote frames unavailable. BlankScreen keeps the machine fully remote-controllable.

## Highlights

- **Zero permissions required.** The global hotkey uses the Carbon `RegisterEventHotKey` API, dispatched by WindowServer itself — no Accessibility or Input Monitoring grants, and it keeps working after every rebuild (ad-hoc signed binaries would otherwise lose TCC grants on each recompile).
- **Menu bar app** (`BlankScreenBar.app`): click the status icon for three clearly-named functions — "关闭显示器" (black out now), "息屏时不睡眠" (auto-keep-awake during every blackout), "合盖后不睡眠" (lid-closed long-running mode) — plus a full settings panel (hotkey, fallback timeout, restore brightness, launch-at-login), built-in hotkey self-test, and log viewer.
- **CLI** (`blankscreen`): `off` / `on` / `status` / `bright` / `config` — works over SSH, and either mode can toggle the other.
- **Crash-safe**: if the app is ever killed while the screen is black, the next launch restores your previous brightness automatically. A configurable fallback timeout (default 12 h) restores the display even if the hotkey dies.
- **Battery guard**: on battery power (and discharging), blanking below a configurable floor (default 20%) is refused, and if the battery drops below the floor mid-blackout the display is restored automatically — a forgotten black screen can no longer drain your Mac. No effect on AC power.
- **Single instance**: launching a second copy takes over cleanly and kills orphaned `caffeinate` helpers.

## Requirements

- macOS 13 Ventura or later (built as a universal binary: Apple Silicon + Intel)
- Built-in display (brightness control via DisplayServices; external monitors without DDC support are not affected)

## Install

**Option A — installer (recommended).** Download `BlankScreen-<version>.pkg` from
[Releases](../../releases) and double-click it. One step, both pieces installed:

| Installed to | Item |
|---|---|
| `/Applications/BlankScreenBar.app` | menu bar app |
| `/usr/local/bin/blankscreen` | CLI |

The installer also clears the Gatekeeper quarantine flag and launches the app for you,
so there is nothing to do by hand.

**Option A2 — DMG drag-and-drop.** Download `BlankScreen-<version>.dmg` from
[Releases](../../releases), open it, and drag the app into Applications.
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

**Option C — download a prebuilt zip** from [Releases](../../releases), then:

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

**Menu bar app** — click ☀ / 🌙 in the menu bar:

- Toggle display / restore
- 防睡眠 (anti-sleep) — keep the system awake while blacked out (see the anti-sleep section)
- 设置… — hotkey combo + key, fallback timeout, restore-brightness policy, launch at login
- 热键自检 — synthesizes your hotkey once and verifies the delivery path (no side effects)
- 打开日志

**CLI**:

```bash
blankscreen off          # black out now (one-shot daemon, auto-restores after timeout)
blankscreen off --timeout 3600
blankscreen on           # restore (also works over SSH while the bar app runs)
blankscreen toggle       # one-command switch — handy for hotkey tools and remote scripts
blankscreen status
blankscreen doctor       # full self-check: display control, processes, leftovers
blankscreen version      # print version (include it when reporting issues)
blankscreen bright 0.5   # read/write system brightness directly
blankscreen service install    # run the CLI as a launchd service (menu app not required)
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
blankscreen config --battery 20      # battery floor %: refuse/exit blackout below it (0 = off)
blankscreen config --auto-nosleep    # link anti-sleep to blackout; auto-reset on restore
```

Default hotkey: **⌃⌥⌘B**. Change it in the settings panel or via `blankscreen config`. The combo must include at least one modifier (⌘/⌃/⌥/⇧) — macOS rejects global hotkeys without one.

**Multiple displays:** blackout applies to every online display. However, most HDMI/DVI/DP
external monitors don't support software brightness, so those panels can't be dimmed —
`blankscreen doctor` tells you exactly which one, instead of leaving you guessing.

## Anti-sleep (keep working with the lid closed / on battery / headless)

Blackout only kills the backlight — the system itself still sleeps on schedule. If the machine must keep working while blacked out (remote access, downloads, closed-clamshell use), enable anti-sleep:

```bash
blankscreen nosleep setup                  # one command: install helper + blackout linkage + start anti-sleep
blankscreen nosleep on                     # process-level (caffeinate; effective on AC power only)
blankscreen nosleep on --system            # system-level (covers battery + lid; requires the helper)
blankscreen nosleep on --timeout 3600      # auto-stop after a duration
blankscreen nosleep status                 # level / power source / uptime
blankscreen nosleep off                    # stop and reset
```

The menu bar app offers the same one-click entry ("一键防睡眠") when the helper is not installed yet.

### Lid-closed anti-sleep (long-running mode)

In the menu bar app, click **"合盖不睡眠（长期运行）"** to enable with one click — no terminal needed:

- **Closed lid = display off, machine keeps running**: downloads, remote access, external displays and long tasks all keep working
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
