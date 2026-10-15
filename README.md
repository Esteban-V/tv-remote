# tv-remote

A small menu bar app for controlling a Samsung TV from a Mac. I got tired of hunting for the physical remote, so now it lives next to the clock.

Built against a 2025 S95F, but anything running Tizen (roughly 2016 and newer) should work, since it uses the same local API the SmartThings phone app uses.

## What it does

- D-pad, OK, back, home, menu, volume, mute, channel, playback keys
- One-click launch for Netflix, YouTube, Stremio and Spotify
- A cleanup button that closes those apps and returns to Home
- Power on via Wake-on-LAN, power off over the network
- Works from the keyboard while the panel is open

| Key | Does |
| --- | --- |
| arrows | navigate |
| return | OK |
| delete | back |
| esc | exit |
| space | play / pause |
| `=` / `-` | volume up / down |
| `0` | mute |
| `h` / `m` | home / menu |

## Install

Grab `TVRemote.zip` from the [latest release](../../releases/latest), unzip it, and drag `TVRemote.app` into Applications.

The app isn't notarized, so macOS will refuse to open it the first time. Either go to System Settings → Privacy & Security and hit "Open Anyway", or run:

```sh
xattr -dr com.apple.quarantine /Applications/TVRemote.app
```

Requires macOS 14 or later.

## Setup

1. Click the TV icon in the menu bar, then the gear.
2. Enter your TV's IP address. Give it a static IP or a DHCP reservation on your router, otherwise this breaks whenever the lease changes.
3. Press any button. The TV pops up an "Allow" prompt the first time; accept it. The token is saved, so it won't ask again.
4. macOS will ask for Local Network access. Allow that too.

For the power button to turn the TV *on*, also fill in the TV's MAC address and enable **Settings → General → Network → Expert Settings → Power On with Mobile** on the TV. Without it, power only works for turning it off.

You can find the IP and MAC under **Settings → General → Network → Network Status → IP Settings**.

## Building from source

Needs the Xcode command line tools.

```sh
./build.sh
```

That compiles a universal binary, wraps it in an app bundle and copies it to `/Applications`. It's a single Swift file with no dependencies, so there's no Xcode project.

Pushing a `v*` tag builds and publishes a release through GitHub Actions.

## Adding apps

App IDs are hardcoded in `shortcuts` near the top of `RemoteView`. To check whether an ID exists on your TV:

```sh
curl http://<tv-ip>:8001/api/v2/applications/<app-id>
```

If you don't know the ID, enable Developer Mode on the TV and use Samsung's `sdb` tool: `sdb connect <tv-ip>` then `sdb shell 0 vd_applist`.

## Known issues

- **The Xbox and Switch (HDMI) buttons don't do anything.** Newer Samsung models ignore input-switching keys sent over the local API, including the Source key. The fix is probably going through the SmartThings cloud API instead, which I haven't done yet.
- App IDs vary by region, so some of the built-in ones may not exist on your TV.
