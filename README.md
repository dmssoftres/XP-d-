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

Arrow and navigation keys are captured as shortcut keys rather than moving
focus while the field is recording. The Globe key is represented as `fn` and
acts only as a modifier, so it must be recorded with another key.

XP[d] stores the recorded physical key code with its modifiers and replays one
key-down/key-up chord through macOS when the mapping runs. Accessibility
post-event access is required; physical button input only checks that permission
silently. Older text-only shortcut mappings remain visible but must be
re-recorded before XP[d] will execute them.

## Additional Standard actions

- **Run macOS Shortcut** stores a Shortcut name and runs it through the system
  `shortcuts` tool.
- **Run AppleScript** provides a multiline AppleScript editor and executes the
  saved source with `osascript`.
- **Run shell command** provides a multiline zsh editor and runs the saved
  command with the current macOS user's permissions.
- **Media control** offers Play/Pause, Next, Previous, Volume Up, Volume Down,
  and Mute.
- **Window / display action** offers Show / hide XP[d], Minimize frontmost
  window, Toggle full screen, Hide frontmost application, Send frontmost window
  to a selected connected screen, and Sleep displays.
  Show / hide XP[d] controls the app's own retained SwiftUI window directly,
  so minimized, closed, and background states do not depend on Accessibility.
  Screen destinations use the display's hardware identity, update when the
  connected-screen set changes, preserve window size, and center the window in
  the target screen's visible area. A disconnected or ambiguous destination
  fails visibly instead of selecting another screen.
- **Switch profile** selects from the current profile list. Renaming a profile
  retargets mappings that point to it; a deleted target fails visibly.
- **No action** intentionally performs nothing and needs no configuration.

Shortcut, AppleScript, and shell mappings preserve their stored content but stay
in **Review required** state until **Enable automation** is selected. Editing the
content or changing its action disables it again. Imported automation is always
disabled locally, even if the exported file marked it enabled. At most four
process-backed actions may run concurrently; duplicate invocations are rejected,
and each run receives a termination request after 30 seconds. Its bounded slot
remains occupied until that original process exits.

Only import configurations containing automation from a trusted source. These
actions can perform any operation available to the current user account.

## Trigger chords

Each Standard action shows one **When pressed** chord with a fixed destination
K button. The chord may also contain any number of designated K modifiers,
Command, Control, Option, Shift, or Fn, and one ordinary keyboard key including
F1–F12. Examples include `K8`, `K10 + K8`, `K9 + K10 + K8`, and
`⌘ + A + K10 + K8`. Recording never replaces the destination button. The
layer menu and captured designated K presses select an exact K layer without
deleting other saved layers.

Keyboard state is sampled when the destination goes down and remains stable
through Tap, Hold, or Double recognition. Only ordinary key codes that appear
in the active profile are queried. The mapping runs only when its keyboard and
K-layer conditions match exactly; clearing removes the optional keyboard
condition while retaining the physical K chord.

## K-button modifier layers

In a Standard profile, any K1–K10 button can be marked **K modifier**. Holding
one by itself through the configured threshold runs its Base Tap immediately.
Pressing a destination K while the modifier remains physically held and before
the threshold cancels standalone and selects that destination's exact alternate
layer. Once the timer fires, later K input in that physical cycle is consumed
and cannot retroactively become a layer. Exact combinations such as `K3`, `K4`,
or `K3 + K4` remain independent.

Designated modifiers use their Base Tap mapping as the standalone hold action;
their Hold and Double mappings remain unavailable because those gestures would
conflict with the held-layer role. The default standalone threshold is 0.5
seconds and is adjustable from 0.2–1.5 seconds under **Status & Input**. A quick
modifier press and release alone does nothing. Layer stacks require exactly one
non-modifier primary K button; ambiguous multi-primary input is consumed.
Turning a designation off preserves its layers and mappings; the inspector keeps
them selectable but muted and delete-only until the MOD is re-enabled.
For a destination K, Base and the selected exact MOD layer have independent
Tap/Hold/Double selectors and configured-state dots, aligned together in the
bottom gesture row. These layer gestures do not change the Tap-only standalone
behavior of the modifier button itself.
The upper MOD-layer field selects exactly one individual or saved layer to
inspect. A separate **Combine MOD buttons** control below it is the only place
that additively builds an exact multi-MOD combination.
Every designated modifier is marked with a persistent `MOD` corner badge on
the graphical remote. The badge overlays the existing button presentation, so
its K number, optional title, and application icon remain in place.

The modifier and destination must overlap in one physical K-input cycle. The
factory report-6 layout ends that cycle with an empty report 6; the programmed
F13–F22 layout uses a verified report-2 `F0` bitfield and ends it with a zero
mask. A release before the threshold makes a lone modifier inert; a later K is
then a new Base cycle. Empty reports 1, 7, and 9 from unrelated composite
collections are ignored and cannot fake that release. Multiple designated
modifiers may be physically overlapped before one destination to select an
exact stacked layer.

Report-2 bindings are learned per profile. After reprogramming the remote,
relearn K1–K10 in each existing Standard or MIDI profile that should use the
new layout. MIDI Fn routing tracks partial report-2 presses and releases without
letting report-6 wheel traffic clear the held Fn state.

Within one held K-input cycle, either press order may select the same exact
layer. A destination-first gesture is reclassified when its designated modifier
arrives before the shared release boundary.

For hardware diagnosis, expand **Status & Input** and read **Raw HID trace**.
It shows the newest 12 normalized reports in chronological order, including
repeated and empty packets. The trace clears on connection changes, remains
local to memory, and does not affect action routing.

A designated modifier must have a usable HID binding. When an older profile is
missing that binding, XP[d] restores only the remote's exact factory signature
when it is not assigned elsewhere; learned bindings are never overwritten.
Clearing a designated modifier's HID binding also turns off its designation but
keeps its saved layer mappings for later re-enabling.

For a non-modifier K button, the inspector keeps the Base action visible in a
left column and shows one chosen exact modifier layer in a right column. Each
column displays its complete **When pressed** chord; the right chord's embedded
layer control selects single or stacked layers without a second modifier UI.

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
