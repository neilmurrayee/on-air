# On Air

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](#)
[![MIT](https://img.shields.io/badge/licence-MIT-green)](LICENSE)

A red **LIVE ON AIR** marquee that appears along the bottom edge of the screen
whenever your camera or microphone goes live, so you don't forget you're being
seen or heard.

It sits one window level *behind* the Dock and matches the Dock's height, so the
text scrolls along the very bottom of the screen and slides out of sight behind the
Dock as it passes. It
floats above every ordinary app window, shows on every Space and over full-screen
apps, and is picked up by screen sharing and recording — so anyone watching your
screen sees it too.

## Build, install, run

```sh
./build.sh --install      # builds, then installs to /Applications
open "/Applications/On Air.app"
```

Only the Xcode Command Line Tools are needed — no Xcode, no project file. Plain
`./build.sh` leaves the app in `build/` without installing it.

### Start at login

```sh
"/Applications/On Air.app/Contents/MacOS/OnAir" --register-login-item
```

Also available as **Open at login** in the menu, and as
`--unregister-login-item` / `--login-item-status`. This has to be run from the
installed binary, because `SMAppService` always acts on the bundle it is running
from — which is also why the app belongs somewhere stable like `/Applications`
rather than `~/Downloads`.

After `./build.sh --install` replaces the bundle, the registration survives; no
need to re-register.

It runs as a menu bar item (a ●) with no Dock icon. Everything is configured from
that menu.

## How it detects a live camera or mic

Three signals, unioned — any one is enough to raise the banner:

| Signal | Property | Notes |
|---|---|---|
| Camera | `kCMIODevicePropertyDeviceIsRunningSomewhere` | Per camera device |
| Microphone | `kAudioDevicePropertyDeviceIsRunningSomewhere` | Per audio input device |
| Microphone | `kAudioProcessPropertyIsRunningInput` | Per process, macOS 14+ |

The device-level audio property is the classic approach, but it reports
**Bluetooth microphones as idle even while they're recording**, so the per-process
property backs it up — and as a bonus it names the app that's live, which is why
the banner can say "Google Chrome". Helper processes (Chrome, Electron, Teams
record from a child process called "Helper") are resolved up to their parent app.

Apple's change listeners for these properties are documented as unreliable —
spurious camera callbacks since macOS 12, and input-running listeners that never
fire at all — so this polls once a second instead of subscribing. That costs
nothing measurable.

**None of this requires any permission**, and the app never opens a camera or mic
itself, so it never lights the orange/green privacy dot on its own.

## Meetings, automatically

There is nothing to start or stop. The bar raises itself the moment a camera or
mic goes live and takes itself down when they stop, polling once a second.

Going on air is instant. Coming off air waits two seconds, because apps genuinely
release the microphone when you hit mute — without the delay the bar would flicker
every time you muted and unmuted mid-call.

## Menu options

- **Watch camera / Watch microphone** — which of the two raise the banner.
- **Position** — bottom edge (default), above the Dock, or automatic (bottom edge
  when the Dock is hidden, above it when it isn't).
- **Height** — "Match the Dock" (default) sizes the bar to the exact strip the Dock
  reserves, tracking it live if you resize the Dock; or pick a fixed slim (22),
  medium (28) or tall (40). The text scales with the height. If the Dock is
  auto-hidden or mounted on a side, the last height seen is reused.
- **Scroll speed** — slow, normal, fast.
- **Scroll behind the Dock** — on by default. Turn it off to float the banner
  above the Dock and the menu bar instead.
- **Show on all displays** — one banner per screen, or just the main one.
- **Ignore** — mute a specific device or app. Useful for virtual audio devices
  (Immersed, Virtual Desktop Mic, BlackHole, Loopback) that report themselves as
  permanently running and would otherwise pin the banner on forever.
- **Preview banner** — force it on to see what it looks like.
- **Open at login** — uses `SMAppService`. macOS often refuses this for an
  unsigned app; if it does, add the app by hand in
  System Settings › General › Login Items.

## Settings not in the menu

Everything lives in `UserDefaults` under `com.local.onair`:

```sh
defaults write com.local.onair bannerText "ON AIR — DO NOT DISTURB"
defaults write com.local.onair bannerHeight -float 34
defaults write com.local.onair scrollSpeed -float 90
```

Quit and relaunch to pick these up.

## Troubleshooting

Run it from a terminal with tracing on to see exactly what the detector sees:

```sh
ONAIR_DEBUG=1 "/Applications/On Air.app/Contents/MacOS/OnAir"
```

It prints a line a second:

```
[11:07:47] watchCam=true watchMic=true cam=false mic=true live=true showing=true apps=["Google Chrome"]
```

If `live=true` when you are not in a meeting, find the culprit in `apps=` or in the
menu's status lines and add it to **Ignore**.

## Sharing it with someone else

### From source (no friction)

They clone the repo and run `./build.sh --install`. They need the Xcode Command
Line Tools (`xcode-select --install`) and nothing else. The build is universal —
Apple Silicon and Intel.

### Sending the built app

`./build.sh --zip` writes `build/On-Air.zip`, built with `ditto` so the signature
survives.

**Be aware of what the recipient sees.** Unless it is signed with a paid Apple
Developer ID and notarised, macOS will refuse to open it — on recent versions the
message is "Apple could not verify 'On Air' is free of malware", with no obvious
way past it. They have to either right-click the app and choose **Open**, or go to
System Settings › Privacy & Security and click **Open Anyway**. Tell them to
expect that, or they will assume the app is broken.

To remove the friction properly you need an Apple Developer ID ($99/year):

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --zip
xcrun notarytool submit build/On-Air.zip --apple-id you@example.com \
    --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple "build/On Air.app"
./build.sh --zip          # re-zip after stapling
```

`build.sh` picks up `SIGN_IDENTITY` automatically and switches on the hardened
runtime, which notarisation requires.

## Known limits

- If someone is sharing a **single window** rather than your whole screen, they
  won't see the banner — it's a separate window.
- The banner is click-through, so it never intercepts anything beneath it.
- Camera device UIDs for some USB webcams look like raw addresses and may change
  across replugging, which only matters if you've added one to the ignore list.
- Browsers sometimes hold the microphone open after a call ends, which keeps the
  bar up. That is technically accurate — the mic really is live — but if it annoys
  you, add the browser to **Ignore**.
- There are no automated tests. Detection, show/hide and geometry were verified by
  hand against real hardware; the multi-display and side-mounted-Dock paths are
  reasoned-through but have not been exercised on real hardware.
- `com.local.onair` is a placeholder bundle identifier.

## Licence

MIT — see [LICENSE](LICENSE).
