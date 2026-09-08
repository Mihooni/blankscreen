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
- **Menu bar app** (`BlankScreenBar.app`): click the status icon for on/off, a full settings panel (hotkey, fallback timeout, restore brightness, launch-at-login), built-in hotkey self-test, and log viewer.
- **CLI** (`blankscreen`): `off` / `on` / `status` / `bright` / `config` — works over SSH, and either mode can toggle the other.
- **Crash-safe**: if the app is ever killed while the screen is black, the next launch restores your previous brightness automatically. A configurable fallback timeout (default 12 h) restores the display even if the hotkey dies.
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

## Usage

**Menu bar app** — click ☀ / 🌙 in the menu bar:

- 关闭显示器 / 恢复显示 — toggle
- 设置… — hotkey combo + key, fallback timeout, restore-brightness policy, launch at login
- 热键自检 — synthesizes your hotkey once and verifies the delivery path (no side effects)
- 打开日志

**CLI**:

```bash
blankscreen off          # black out now (one-shot daemon, auto-restores after timeout)
blankscreen off --timeout 3600
blankscreen on           # restore (also works over SSH while the bar app runs)
blankscreen status
blankscreen bright 0.5   # read/write system brightness directly
blankscreen service install    # run the CLI as a launchd service (menu app not required)
blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200
```

Default hotkey: **⌃⌥⌘B**. Change it in the settings panel or via `blankscreen config`. The combo must include at least one modifier (⌘/⌃/⌥/⇧) — macOS rejects global hotkeys without one.

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

## Development

```bash
make            # build CLI + app into build/
make dev-tools  # build debugging helpers into build/dev-tools/
make clean
```

Source layout: `Sources/blankscreen.swift` (CLI), `Sources/BlankScreenBar.swift` (menu bar app), `dev-tools/` (screenshot/brightness/probe helpers used during development).

## Known limitations

- **External displays are not dimmed.** Brightness is only set on the main display
  (`CGMainDisplayID`). With an external monitor attached, the built-in display goes dark
  while the external one keeps showing its image. Covering every display would need
  DDC/CI, which Apple Silicon does not expose reliably.

- The panel is **not powered down** — this is intentional. Backlight is driven to 0, so
  the framebuffer keeps rendering and screen-sharing / remote-desktop sessions keep
  working. True display sleep would break remote access; see [How it works](#how-it-works).

## License

[MIT](LICENSE)
