# UtsuriPanel

A desk panel on an old Android phone. While [HagtAmp](https://github.com/mmag/hagtamp) plays, the phone shows the player's own display: the time, the classic visualizer and the scrolling title, pixel for pixel in the current skin. When nothing plays, it cycles through this Mac's load, the home servers (node_exporter) and their disks' SMART health (Scrutiny).

```
HagtAmp ── ws://127.0.0.1:24248 ──┐  display frames, status, skin colors
node_exporter, Scrutiny ── HTTP ──┤
                                  ▼
                  UtsuriPanel.app (menu bar, Mac)
                  serves web/ and one WebSocket on 127.0.0.1:26472,
                  keeps `adb reverse` up and the phone's app open
                                  │ USB, adb reverse
                                  ▼
                  phone: UtsuriPanel (full-screen WebView)
```

## Parts

- `daemon/` — `UtsuriPanel.app`, a menu bar app (Swift, no dependencies):
  - serves the page and the panel WebSocket, relaying HagtAmp's feed;
  - samples the Mac (CPU per core, memory, network, disk, battery);
  - polls node_exporter (CPU, temperatures, md RAID, filesystems, network) and Scrutiny (disks);
  - whenever the phone shows up without the port reversed (plugged in, rebooted), reverses it and opens the app.

  The menu shows the phone and its battery, the player, servers and disks, and reloads the panel.
- `web/index.html` — the panel: swipeable screens, rendered from the WebSocket messages.
- `android/` — the phone app: the page full screen, kept on, over the lock screen, started at boot. Built with the SDK's tools directly, no Gradle.

## Screens

HagtAmp's display, a split-flap clock, the Mac, one screen per node_exporter, and the disks, in a ring: swipe either way. When music starts the panel goes to HagtAmp's display, 15 s after it stops or pauses to the clock, and stays there; a touch holds it for 15 s.

A disk in trouble (SMART or Scrutiny's thresholds failed, or Scrutiny's risk isn't "healthy") flashes the screen red and holds the disks screen for a minute, again every hour while it lasts; meanwhile the disks' dot is red and the clock names the disk instead of the date.

## Setup

1. **HagtAmp**: Preferences → General → Visualizer feed.
2. **Servers**: [node_exporter](https://github.com/prometheus/node_exporter) and/or [Scrutiny](https://github.com/AnalogJ/scrutiny) reachable from the Mac.
3. **Phone** (Android 7.1+): enable USB debugging and allow the Mac. On Android 7–9 pick Chrome as the WebView (Developer options → WebView implementation, or `adb shell cmd webviewupdate set-webview-implementation com.android.chrome`); a ROM's own WebView may be too old. Then `android/build.sh --install` (needs the Android SDK; uses the debug key).
4. **Mac**: `daemon/install.sh` builds `/Applications/UtsuriPanel.app`, installs its LaunchAgent (started at login, restarted if it crashes) and creates `config.json` from `config.example.json` on the first run. Put your servers in it and run `install.sh` again. Allow it on the local network when macOS asks. Log: `~/Library/Logs/utsuripanel.log`; `install.sh --uninstall` removes it all.

## config.json

| Key | |
|---|---|
| `port` | the panel's port on 127.0.0.1, also reversed to the phone |
| `web` | the page's folder, relative to the config |
| `hagtamp` | HagtAmp's feed |
| `adb` | path to adb |
| `app` | the phone's activity to open |
| `nodes` | `{name, url}` of node_exporter `/metrics` |
| `scrutiny` | `{name, url}` of Scrutiny web roots |

## Panel WebSocket

Any request to the daemon's port that asks for a WebSocket upgrade gets one. New panels first receive the latest message of each kind.

- Binary: HagtAmp's display frames, as HagtAmp sends them: `[type][width][height][0][seq u32 LE]` + RGBA. Type 1 is the display (status, time, visualizer, 83×42), type 2 the title (155×6).
- `{"type":"skin"}` and `{"type":"status"}` from HagtAmp; while HagtAmp isn't running the daemon sends `status` with `"offline": true`.
- `{"type":"mac"}` every 2 s, `{"type":"node","name":…}` every 5 s, `{"type":"disks"}` every 5 minutes (sooner after a failure).
