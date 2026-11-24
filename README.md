# Switch

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![GitHub release](https://img.shields.io/github/v/release/Blprk/switch)](https://github.com/Blprk/switch/releases)
[![Stars](https://img.shields.io/github/stars/Blprk/switch?style=social)](https://github.com/Blprk/switch/stargazers)

A tiny native macOS menu-bar app that keeps your Mac awake — only when you want it to. No `caffeinate` subprocess, no `sudo`, no bloat. It is installed as **Switch Everywhere**; the menu bar and popup show the short name **Switch**.

![Switch menu bar indicator](assets/menubar.png)

![Switch popup](assets/popup.png)

## Why

`caffeinate` dies when its shell session ends, can't tell you its state, and keeps fighting sleep with the lid closed. Switch fixes all three:

- 🟢 **Clear on/off state** — fixed-width menu bar indicator plus a real pill toggle in the popup
- 🔒 **Native IOPM assertions** held directly by the app — no subprocess, no `sudo`
- 💻 **Lid close on AC keeps working** (clamshell); on battery it pauses and resumes when reopened
- 🕐 **Six session modes** — indefinite, minutes, hours, until a time, while an app runs, while files download
- 🧹 **Fully reversible** — three commands remove everything

## Features

| Feature | Detail |
|---|---|
| Core | `PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`, `PreventSystemSleep`, `PreventDiskIdle`, `UserIsActive` |
| Configurable groups | Display / System / Disk assertions can be toggled independently |
| Sessions | Indefinite, Minutes, Hours, Other/Until, While App Running, While Downloading |
| Downloads | Safari `Downloads.plist`, Chromium `History` DB state=0, plus folder heuristic |
| AppleScript | `session is active`, `start session [minutes]`, `end session`, `time remaining` |
| Diagnostics | Event log + "Copy Diagnostics" button |
| Login | Enable/disable LaunchAgent from popup |
| Size | ~175 KB (`-Osize`, dead-strip, stripped) |

## Install

Requires macOS 11+ and the Xcode Command Line Tools (`xcrun swiftc`). The build produces a **universal** binary (x86_64 + arm64), so it runs on both Intel and Apple Silicon Macs.

```bash
git clone https://github.com/Blprk/switch.git
cd switch
./scripts/build.sh
```

The app is installed to `~/Applications/Switch Everywhere.app`. It is menu-bar only (`LSUIElement`) — there is no Dock icon, so look for the **Switch** indicator in the menu bar. To start it at login, open the popup and turn on **Settings → Login at startup**; the build script does not install the LaunchAgent for you.

### Manual

```bash
swiftc -Osize -o "$HOME/Applications/Switch Everywhere.app/Contents/MacOS/SwitchEverywhere" \
  src/main.swift -framework Cocoa -framework IOKit -Xlinker -dead_strip
cp Info.plist "$HOME/Applications/Switch Everywhere.app/Contents/Info.plist"
cp SwitchEverywhere.sdef "$HOME/Applications/Switch Everywhere.app/Contents/Resources/SwitchEverywhere.sdef"
```

Then enable **Settings → Login at startup** in the popup to create and register the LaunchAgent.

## Distribute

Every build is universal, so one artifact covers all supported Macs. Run `./scripts/build.sh --help` for all options.

### Unsigned zip (free)

```bash
./scripts/build.sh --no-install --zip
# -> dist/Switch Everywhere-2.1.2.zip
```

Send that zip with these notes:

```bash
unzip "Switch Everywhere-2.1.2.zip" -d ~/Applications
xattr -dr com.apple.quarantine "$HOME/Applications/Switch Everywhere.app"
open "$HOME/Applications/Switch Everywhere.app"
```

`xattr -dr com.apple.quarantine ...` removes the download quarantine; right-clicking the app and choosing **Open → Open** does the same thing. Then enable **Settings → Login at startup**. Because the app is unsigned, macOS shows an "unidentified developer" warning on first run — that is expected.

### Notarized zip (no warnings for recipients)

Requires an Apple Developer Program membership and a **Developer ID Application** certificate in your Keychain.

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID=you@example.com \
APPLE_TEAM_ID=TEAMID \
APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
./scripts/build.sh --no-install --notarize
```

This signs with the hardened runtime and a secure timestamp, submits the zip to Apple, staples the ticket, and re-zips the stapled app. To avoid putting your password on the command line, save a keychain profile once and reuse it:

```bash
xcrun notarytool store-credentials switch-notary \
  --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx

NOTARY_PROFILE=switch-notary \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./scripts/build.sh --no-install --notarize
```

Upload `dist/Switch Everywhere-<version>.zip` to a GitHub Release. Recipients still click **Open** once, but Gatekeeper will identify you as the developer. A DMG is optional — it is only a container and does not change Gatekeeper behavior. For Homebrew users, a Cask in your own tap that downloads the zip is a convenient extra.

There is no auto-updater: recipients replace the `.app` manually to upgrade, so include the version number.

## Usage

- Click the menu bar indicator to open the popup
- Click the **pill toggle** next to **Switch** for instant on/off
- Pick a session under **Start New Session**
- **Settings** controls assertion groups, download folder, default session, menu bar style, and login
- **Live info**, **Sleep/Wake Log**, and **Debug Log** are always visible with wrapping text

### AppleScript

```applescript
tell application "Switch Everywhere"
    session is active
    start session 15
    time remaining
    end session
end tell
```

### Verify

```bash
pmset -g assertions | grep "Switch Everywhere"
launchctl print gui/$(id -u)/com.user.keepawakeapp | grep 'job state'
```

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.user.keepawakeapp
rm ~/Library/LaunchAgents/com.user.keepawakeapp.plist
rm -rf "$HOME/Applications/Switch Everywhere.app"
```

## Safety

No `sudo`, no system files, no `pmset` changes, no network, no telemetry. Assertions are released by the kernel if the app dies. User-initiated and low-battery sleep still work. On battery, closing the lid pauses assertions; on AC, the Mac can run in clamshell mode.

## Code notes

Single `src/main.swift` with `// MARK:` sections: Models, Lifecycle, State machine, Assertions, Monitoring, Downloads, UI, AppleScript, Stats. All transitions go through `transition(to:event:)`; the menu-bar status item is fixed-width so the popover never shifts when toggled; the popover size is pinned so content is never clipped.

## License

[MIT](LICENSE) © 2026 [Blprk](https://github.com/Blprk)

The GitHub repository is named **switch**; the installed application is **Switch Everywhere**, shown as **Switch** in the UI.
