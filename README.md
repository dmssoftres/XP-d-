# XP[d]

A native macOS utility for turning the XPPen/HANWUGEE Shortcut Remote into a programmable controller.

XP[d] can also host typed MIDI profiles and publishes two virtual MIDI sources:
`XP[d] Control` for DAW Remote mappings and `XP[d] Performance` for notes,
drums, and chords.

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
press. Hold the center while rotating to highlight a profile, then release the
center to confirm it. Rotation previews a profile without activating it.

## HID learning

Select a control in the remote drawing, choose **Learn selected control**, then press the matching physical control. XP[d] stores the raw report signature locally and highlights the matching visual control when that report is received again.

The dial is captured through its relative HID Wheel/AC Pan value rather than
the button report path. Select either rotation side of the visual wheel to edit
the unified wheel action. The wheel scrolls vertically by default, with a
persisted sensitivity setting from 1 through 10. Counter-clockwise scrolls up
and clockwise scrolls down.

## Button gestures

K1–K10 recognize Tap, Hold, and Double from the verified button-down and
generic-release HID stream. Tap waits 0.30 seconds so a second press can become
Double; Hold fires once after 0.72 seconds while the button remains pressed.
Pending gestures are cancelled when the profile/configuration changes, the
remote disconnects, learning begins, or another live button displaces the
current one. Wheel rotation and the device-specific wheel-center profile
selector remain outside this timing path.

## Application actions

Select a control, choose **Open application** or **Toggle application**, and enter
an app name such as `ChatGPT` in **Command**. Open application launches or focuses
the app. Toggle application opens a closed app, restores a background or minimized
app, and minimizes it when it is already frontmost.

Restoring and minimizing another app's windows requires XP[d] to be enabled once
in **System Settings › Privacy & Security › Accessibility**. No AppleScript or
shell command is required.

## Keyboard shortcut capture

Choose **Keyboard shortcut** for a K-button gesture, then click the shortcut
field to start recording. Hold any combination of Command, Control, Option,
Shift, and Fn, then press one non-modifier key; click the field again to save
that simultaneous chord. The remote K buttons remain the controls that trigger
mappings—they are not part of a recorded keyboard shortcut. Escape, changing
the selected control or gesture, or choosing another action cancels without
changing the existing mapping. While recording, modifier and key chips can be
removed independently; the clear button removes either the draft or saved
shortcut.

XP[d] stores the recorded physical key code with its modifiers and replays one
key-down/key-up chord through macOS when the mapping runs. Accessibility
post-event access is required; physical button input only checks that permission
silently. Older text-only shortcut mappings remain visible but must be
re-recorded before XP[d] will execute them.

## Remote trigger chords

In a Standard K-button mapping, **Remote trigger** records the physical button
as a special key together with any combination of Command, Control, Option,
Shift, Fn, and one held F1–F12 key. Click to start, hold special keys, press a
remote K button, then click again to save—for example, `⌘F4K4`. The modifier
and function-key state is sampled when the button goes down, so it remains
stable through Tap, Hold, or Double recognition. The mapping runs only when
the held keys exactly match its saved trigger; clear the trigger keys to restore
the plain K-button behavior. One modifier-gated trigger is stored per K-button
gesture.

In Standard profiles, select K1–K10 to set an optional **Button title**. The
title appears as one compact line at the top of that button and is shared by
its Tap, Hold, and Double mappings. Titles are profile-specific, limited to 24
characters, and do not appear in MIDI profiles.

## MIDI profiles

Create a profile with the MIDI realm to edit Note, CC, Program Change, Chord,
wheel, and Pitch Bend output. Each mapping chooses the Control or Performance
source. MIDI Lock keeps wheel-based profile selection inside the MIDI realm;
the main window and menu-bar menu always provide a direct escape. A profile may
reserve K1-K10 or wheel center as a momentary Fn control for its second layer.
Physical Fn rollover—especially center plus wheel—still requires target-device
acceptance and is never replaced with a latch.

The MIDI inspector includes a live monitor for acceptance and troubleshooting.
It reports the messages XP[d] actually sends—including Note On/Off and failed
attempts—with their port, decoded values, and raw UMP word. Use **Copy** to
share the newest 100 entries or **Clear** before a focused hardware test.

## Configuration files

Use **Import** and **Export** in the mapping inspector to move or back up the
complete XP[d] setup as readable JSON. Use the profile-management button beside
the header picker to add, rename, or remove profiles. Global cannot be renamed
or removed. The version 5 file preserves profile order and contains every
profile's realm, complete Tap, Hold, and Double mappings and HID bindings,
optional Standard button titles, plus the active profile and overlay
preference. MIDI profiles additionally contain typed primary/Fn mappings.
Version 2, 3, and 4 exports upgrade on import, and invalid imports are rejected
before the current setup is replaced.

## Remote battery

When the matching Shortcut Remote exposes the verified vendor notification, XP[d] shows its exact battery percentage in the window header and menu-bar submenu. The BLE path is notify-only, requires the target's exact PnP identity, and never sends undocumented commands. If exact telemetry is absent or invalid, the app shows `Battery unavailable` rather than estimating.

## Development permissions and relaunches

Accessibility and Input Monitoring approval are tied to the app's code signature. This repository uses standard ad-hoc signing because no Apple Development identity is configured on the current Mac. If permissions become stale after a rebuild, run:

```sh
./script/build_and_run.sh --reset-permissions
```

This stops XP[d], resets its Accessibility and Input Monitoring records, opens the Accessibility settings page, and launches the already-built bundle so it can be approved. Approve XP[d] in Accessibility, then use `./script/build_and_run.sh --relaunch` to restart the same bundle without rebuilding or changing its signature. The older `--reset-input-monitoring` mode remains available when only Input Monitoring needs to be reset.
