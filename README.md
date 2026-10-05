# On Air

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](#)
[![MIT](https://img.shields.io/badge/licence-MIT-green)](LICENSE)

A red **LIVE ON AIR** bar along the bottom edge of the screen, and a thin red frame
around it, whenever your camera or microphone goes live, so you don't forget you're
being seen or heard.

The bar sits one window level *behind* the Dock and matches the Dock's height, with
the message repeated along it so it shows either side of the Dock. It can also
scroll, marquee-style, sliding out of sight behind the Dock as it passes. It
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
fire at all — so this mostly polls. (Tested: the per-app "recording input"
notification never fired, while polling caught every change.) Each poll is one
small request to the system audio service per device and per process that has
used audio, about 9 ms in total with ~35 of them, done on a background thread so a
busy audio service can never stall the menu or the banner.

The one notification that does work is an audio device's "running somewhere", so
a mic device starting or stopping triggers a check at once, and the full poll runs
only every three seconds to catch the rest: cameras, and apps on Bluetooth mics.
That keeps the audio service's extra load under 1% of its CPU, and neither the
camera nor your call app notices.

**None of this requires any permission**, and the app never opens a camera or mic
itself, so it never lights the orange/green privacy dot on its own.

## Meetings, automatically

There is nothing to start or stop. The bar raises itself the moment a camera or
mic goes live and takes itself down when they stop.

Going on air takes at most three seconds, and is usually immediate for a wired or
built-in mic. Coming off air waits a further two seconds, because apps genuinely
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
- **Red border around the screen** — on by default.
- **Scroll the text** — off by default. Still, the bar and border cost nothing
  once drawn; scrolling makes WindowServer redraw every frame for as long as you
  are live, about 7% of its CPU on a 60 Hz display (more on 120 Hz).
- **Scroll speed** — slow, normal, fast.
- **Bar behind the Dock** — on by default. Turn it off to float the banner
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
defaults write com.local.onair scrollFrameRate -float 30   # cheaper scrolling
defaults write com.local.onair borderWidth -float 6
```

Quit and relaunch to pick these up.

## Troubleshooting

Run it from a terminal with tracing on to see exactly what the detector sees:

```sh
ONAIR_DEBUG=1 "/Applications/On Air.app/Contents/MacOS/OnAir"
```

It prints a line for every check, every three seconds or on a device change:

```
[11:07:47] watchCam=true watchMic=true cam=false mic=true live=true showing=true apps=["Google Chrome"] read=8.6ms
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

**What the recipient sees, and exactly what to tell them.** Unless the app is
signed with a paid Apple Developer ID and notarised, macOS refuses to open it:
*"Apple could not verify 'On Air' is free of malware."*

Note that the old advice — Control-click the app and choose **Open** — **no longer
works**. Apple removed that bypass in macOS 15 Sequoia. Anyone repeating it (or any
tool trained on pre-2024 answers) will send you down a dead end. On macOS 15 and
later the steps are:

1. Double-click the app. Click **Done** on the warning.
2. Open **System Settings › Privacy & Security**, scroll to **Security**. There is a
   line reading *"On Air" was blocked to protect your Mac* with an **Open Anyway**
   button.
3. Click **Open Anyway**, confirm, and authenticate.

Only step 2 works — and only if attempted shortly after step 1, since the button
appears in response to the blocked launch.

The terminal equivalent, if you prefer:

```sh
xattr -dr com.apple.quarantine "/Applications/On Air.app"
```

Worth saying plainly: that command is also precisely what malware distributors ask
people to run, so some recipients will decline on principle, and they are not being
unreasonable. It is a trust decision rather than a technical obstacle. Leading with
the source repo sidesteps it entirely — code someone can read needs no such leap.

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
- The tests (see below) cover the detection logic and banner geometry with fake
  readings, plus performance against the real hardware. Show/hide was verified by
  hand; the multi-display and side-mounted-Dock paths are reasoned-through but have
  not been exercised on real hardware.
- `com.local.onair` is a placeholder bundle identifier.

## Licence

MIT — see [LICENSE](LICENSE).

## Tests and performance

```sh
./build.sh --test     # logic tests, then performance budgets
./build.sh --bench    # performance only, longer runs
Tests/camera_ab.sh    # camera frame rate and WindowServer CPU, with and without On Air
```

The performance checks read the real hardware, so they say how this Mac is doing:
how long a hardware read takes, and whether the main thread stays responsive while
the monitor polls (it should be indistinguishable from idle). Neither opens a camera
or mic, so they are safe to run during a call. `camera_ab.sh` does open the camera,
so run it when nothing else is using it.
