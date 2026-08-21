# XP[d]

A native macOS utility for turning the XPPen/HANWUGEE Shortcut Remote into a programmable controller.

Initial target device:
- Vendor ID: `10429`
- Product ID: `514`
- Product string: `Shortcut Remote`
- Transport: Bluetooth Low Energy

## v0.1 goals

- Native SwiftUI app with a compact gray macOS UI.
- Vertical 1:1 remote layout matching the physical device orientation.
- Direct HID device discovery and event logging.
- Learn and persist the real HID report emitted by each physical control.
- Select a physical/visual control and assign actions.
- Persist mappings locally.
- Menu-bar presence plus a normal configuration window.
- A click-through Key Stack overlay shows recent remote inputs and hold progress
  in the top-right corner. It can be disabled from the XP[d] menu-bar menu.

The target remote's standalone empty report 6 is treated as the wheel-center
press. Press once to open the persistent profile selector, rotate to highlight
a profile without activating it, and press again to confirm.

## HID learning

Select a control in the remote drawing, choose **Learn selected control**, then press the matching physical control. XP[d] stores the raw report signature locally and highlights the matching visual control when that report is received again.

The dial is captured through its relative HID Wheel/AC Pan value rather than
the button report path. Select either rotation side of the visual wheel to edit
the unified wheel action. The wheel scrolls vertically by default, with a
persisted sensitivity setting from 1 through 10. Counter-clockwise scrolls up
and clockwise scrolls down.

## Application actions

Select a control, choose **Open application** or **Toggle application**, and enter
an app name such as `ChatGPT` in **Command**. Open application launches or focuses
the app. Toggle application opens a closed app, restores a background or minimized
app, and minimizes it when it is already frontmost.

Restoring and minimizing another app's windows requires XP[d] to be enabled once
in **System Settings › Privacy & Security › Accessibility**. No AppleScript or
shell command is required.

## Configuration files

Use **Import** and **Export** in the mapping inspector to move or back up the
complete XP[d] setup as readable JSON. The version 2 file contains Global,
Finder, and Logic Pro, with each profile's complete Tap, Hold, and Double
mappings and HID bindings, plus the active profile and overlay preference.
Imports are validated completely before the current setup is replaced.

## Remote battery

When the matching Shortcut Remote exposes the verified vendor notification, XP[d] shows its exact battery percentage in the window header and menu-bar submenu. The BLE path is notify-only, requires the target's exact PnP identity, and never sends undocumented commands. If exact telemetry is absent or invalid, the app shows `Battery unavailable` rather than estimating.

## Development permissions and relaunches

Accessibility and Input Monitoring approval are tied to the app's code signature. This repository uses standard ad-hoc signing because no Apple Development identity is configured on the current Mac. If permissions become stale after a rebuild, run:

```sh
./script/build_and_run.sh --reset-permissions
```

This stops XP[d], resets its Accessibility and Input Monitoring records, opens the Accessibility settings page, and launches the already-built bundle so it can be approved. Approve XP[d] in Accessibility, then use `./script/build_and_run.sh --relaunch` to restart the same bundle without rebuilding or changing its signature. The older `--reset-input-monitoring` mode remains available when only Input Monitoring needs to be reset.
