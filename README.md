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

## Download and install

Go to the **[Releases page](https://github.com/Blprk/switch/releases)** and download `SwitchEverywhere-<version>-macos.zip` from the release marked **Latest**. One zip works on Intel and Apple Silicon Macs running macOS 11 or newer.

> **What is a release?** GitHub Releases is the download page for a project. Each release collects the files for one version under **Assets**, and the release tagged **Latest** is the newest one.

1. Unzip the file and move **Switch Everywhere.app** into `~/Applications` (or wherever you keep apps).
2. Right-click the app and choose **Open → Open**. This one-time step is needed because the app is unsigned. If macOS does not offer Open, run `xattr -dr com.apple.quarantine "$HOME/Applications/Switch Everywhere.app"` in Terminal.
3. Look for **Switch** in the menu bar — there is no Dock icon. Click it and turn on **Settings → Login at startup** if you want it to launch automatically.

To update, come back to the Releases page, download the newest zip, and replace the old app. There is no auto-updater.

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

## For developers

### Build from source

Requires macOS 11+ and the Xcode Command Line Tools (`xcrun swiftc`). The build is universal (x86_64 + arm64).

```bash
git clone https://github.com/Blprk/switch.git
cd switch
./scripts/build.sh
```

This installs to `~/Applications/Switch Everywhere.app`. Add `--no-install` to skip installing, and see `./scripts/build.sh --help` for all options.

### Make a release

1. Bump both version keys in `Info.plist`, commit, and use the same number for the tag (`vX.Y.Z`).
2. Build the zip: `./scripts/build.sh --no-install --zip` → `dist/SwitchEverywhere-<version>-macos.zip`.
3. Publish it:

```bash
gh release create v<version> dist/SwitchEverywhere-<version>-macos.zip \
  --title "v<version> — short description" --notes "What changed..."
```

To add a zip to an existing release, use `gh release upload v<version> dist/SwitchEverywhere-<version>-macos.zip`. On the web, use **Releases → Draft a new release →** enter the tag → attach the zip under **Assets → Publish release**. The release then becomes **Latest** and the download link above points to it.

### Signing and notarization (optional)

The published zip is unsigned, so users click **Open** once on first run. To remove that step you need an Apple Developer Program membership and a **Developer ID Application** certificate in your Keychain:

```bash
NOTARY_PROFILE=switch-notary \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./scripts/build.sh --no-install --notarize
```

Create the profile once with `xcrun notarytool store-credentials switch-notary --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx`. The script signs with the hardened runtime, notarizes, staples the ticket, and re-zips. Upload that zip instead.

## Code notes

Single `src/main.swift` with `// MARK:` sections: Models, Lifecycle, State machine, Assertions, Monitoring, Downloads, UI, AppleScript, Stats. All transitions go through `transition(to:event:)`; the menu-bar status item is fixed-width so the popover never shifts when toggled; the popover size is pinned so content is never clipped.

## License

[MIT](LICENSE) © 2026 [Blprk](https://github.com/Blprk)

The GitHub repository is named **switch**; the installed application is **Switch Everywhere**, shown as **Switch** in the UI.
