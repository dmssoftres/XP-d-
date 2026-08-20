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

The wheel-center button is detected from its special empty keyboard report and
can be mapped from the same inspector as every other control. XPPen's driver
continues to cycle the wheel function group when the button is pressed.

## HID learning

Select a control in the remote drawing, choose **Learn selected control**, then press the matching physical control. XP[d] stores the raw report signature locally and highlights the matching visual control when that report is received again.

The dial is captured through its relative HID Wheel/AC Pan value rather than the button report path. Learn clockwise and counter-clockwise separately by selecting each visual wheel direction and turning the physical dial once.

## Development relaunches

Input Monitoring approval is tied to the app's code signature. This repository uses standard ad-hoc signing because no Apple Development identity is configured on the current Mac. Rebuilding may therefore require `./script/build_and_run.sh --reset-input-monitoring` and one fresh approval. Once approved, use `./script/build_and_run.sh --relaunch` to restart the existing bundle without changing its signature.
