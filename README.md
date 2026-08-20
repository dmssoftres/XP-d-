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

The wheel-center button remains unresolved because the remote has not exposed a
unique HID report for it.

## HID learning

Select a control in the remote drawing, choose **Learn selected control**, then press the matching physical control. XP[d] stores the raw report signature locally and highlights the matching visual control when that report is received again.

The dial is captured through its relative HID Wheel/AC Pan value rather than the button report path. Learn clockwise and counter-clockwise separately by selecting each visual wheel direction and turning the physical dial once.

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
complete XP[d] setup as readable JSON. The file contains every control's Tap,
Hold, and Double mapping, HID bindings, the current profile name, and the overlay
preference. Imports are validated completely before the current setup is replaced.

## Development relaunches

Input Monitoring approval is tied to the app's code signature. This repository uses standard ad-hoc signing because no Apple Development identity is configured on the current Mac. Rebuilding may therefore require `./script/build_and_run.sh --reset-input-monitoring` and one fresh approval. Once approved, use `./script/build_and_run.sh --relaunch` to restart the existing bundle without changing its signature.
