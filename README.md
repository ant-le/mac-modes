# Mac Modes

A Swift menu-bar app for switching Mac workflows, with Logitech Actions Ring
hotkeys and local screen-text recognition. Requires macOS 13+ and Apple's
command-line tools to build. No third-party Swift packages.

## Modes

- **Normal:** disconnect Proton and Tailscale; stop OrbStack.
- **Coding:** disconnect Proton; start Tailscale and OrbStack; open and resize T3.
- **Music:** disconnect VPNs; stop OrbStack; open and resize Traktor.
- **Private:** disconnect Tailscale; stop OrbStack; verify Proton VPN; open Zen.
  Select Zen's Privacy container manually.

Install and authenticate the apps you use. Focus/DND and AirDrop stay under manual
control. Leaving Coding asks before stopping running OrbStack workloads.
Launching T3 enters Coding (with confirmation from Music or Private); quitting it
returns active Coding to Normal. Normal is the reboot default.

## Install

```sh
scripts/install.sh
bin/modectl status
```

Run the installer again to update. It installs `~/Applications/Mac Modes.app`,
launchers in `~/Applications/Mac Modes Launchers`, and a login agent. Configuration
and state are preserved; deployment backups live under
`~/Library/Application Support/MacModes/backups`.

## Controls and permissions

Choose a mode from the menu bar, or assign these keys in Logitech Options+:

| Action | Hotkey |
| --- | --- |
| Toggle Coding | Control + Command + 7 |
| Toggle Music | Control + Command + 6 |
| Toggle Private | Control + Command + 8 |
| Copy screen text | Control + Command + 9 |

Mode hotkeys toggle back to Normal when selected again. Options+ can also open a
launcher app: **Mode Coding**, **Mode Music**, **Mode Private**, **Mode Normal**, or
**Copy Screen Text**. If a hotkey conflicts, change the competing binding or use a
launcher.

For OCR, press the hotkey and drag a rectangle. Recognition runs locally and copies
text to the clipboard; cancellation or no text leaves it unchanged. Allow
**Screen Recording** in System Settings → Privacy & Security when prompted.
For T3/Traktor window resizing, use **Settings → Allow window resizing…** in the
app menu to grant **Accessibility** access. Switching overlays can also be disabled
in Settings.

Automation supports `macmodes://toggle/coding`, `macmodes://toggle/music`,
`macmodes://toggle/private`, `macmodes://set/normal`, and `macmodes://ocr`, or the CLI:

```sh
bin/modectl set coding --wait
bin/modectl toggle music
bin/modectl set normal --wait
bin/modectl status
bin/modectl doctor
bin/modectl ocr
```

After fixing a failed transition, retry with `set <mode>`. State and logs are in
`~/Library/Application Support/MacModes`.

## Configuration

Edit `~/Library/Application Support/MacModes/config.json` to override
[bundled defaults](config/default.json), including app paths and bundle IDs.
Changes apply between transitions without rebuilding. `config/local.json` is an
untracked developer override, imported on install only if no runtime config exists.

App closing is off by default. To quit Traktor when leaving Music:

```json
{ "close_apps_on_exit": { "music": true } }
```

The `coding` flag does the same for T3. Enabled flags close all instances of that
app, including ones opened manually. Unsaved-work dialogs block the transition;
respond and retry. Apps are never force-quit; Zen stays open.

## Private mode

Keep Proton's kill switch enabled. Private checks VPN connectivity, tunnel routing,
and Proton's location endpoint before opening Zen, then monitors the connection.
A failed check reports an error; it cannot guarantee zero leaks or close sensitive
tabs for you. Close those tabs before leaving Private: Zen stays open while Proton
disconnects. Proton affects all apps.

## Development

```sh
scripts/test.sh
scripts/build.sh
```

Core logic is in `Sources/MacModesCore`; the menu app, CLI, and launchers are in
`Sources/MacModes`, `Sources/modectl`, and `Sources/ModeLauncher`. Regression tests
in `tests/MacModesCoreTests` avoid changing live VPNs or quitting apps. Permissions,
Ring clicks, region selection, and window layouts need manual checks.

Build output is `build/standalone/` and `build/MacModes-standalone.zip`. Bundles are
ad-hoc signed for local use, not notarized.

## Disable login startup

Return to Normal successfully, then unload and remove the login agent:

```sh
bin/modectl set normal --wait
launchctl bootout "gui/$(id -u)/local.mac-modes.menubar"
rm "$HOME/Library/LaunchAgents/local.mac-modes.menubar.plist"
```

The app and its data remain installed. Reinstall to restore login startup.
