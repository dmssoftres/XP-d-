<p align="center">
  <img src="Resources/AppIcon.png" alt="XP[d] app icon" width="160">
</p>

# XP[d]

A native macOS utility for turning the XPPen/HANWUGEE Shortcut Remote (ACK05) into a programmable controller.

XP[d] can also host typed MIDI profiles and publishes two virtual MIDI sources:
`XP[d] Control` for DAW Remote mappings and `XP[d] Performance` for notes,
drums, and chords.

> **Unofficial project.** XP[d] is not made, endorsed or supported by XPPen
> or Hanvon Ugee. XPPen is a trademark of its owner, used here only to name
> the hardware this app works with. No XPPen software, firmware or code is
> included or distributed.

Like XP[d]? [Buy me a liquid noradrenaline-dopamine rush at Ko-fi](https://ko-fi.com/dmssoftres) ☕

## Installation (new users)

XP[d] is free and is not sold through the App Store. There are two ways to
install it:

- **Option A — ready-made download (quickest).** Download the app and allow it
  once in System Settings. See *Quick install* below.
- **Option B — build it yourself (Steps 1–3).** About five minutes; you copy a
  few commands into the Terminal app. macOS opens an app you built yourself
  without any warning.

Then continue with Step 4 either way.

### Quick install (ready-made download)

1. Open this project's **Releases** page (right-hand side of the GitHub page)
   and download the latest `XPd-….zip`.
2. Double-click the zip to unzip it, then drag **XP[d].app** into your
   **Applications** folder.
3. Double-click XP[d]. macOS will say it cannot check the app for malicious
   software and refuse to open it. Click **Done** (not *Move to Trash*).

**Why the warning?** Apple only trusts apps whose developer pays for an Apple
Developer membership and sends every version to Apple for checking
("notarisation"). XP[d] is a free hobby project and is not notarised. The
whole source code is on this page, so you can read it, or build it yourself
with Option B instead.

**Allow XP[d] once (Apple's official way):**

4. Open **Apple menu › System Settings › Privacy & Security**.
5. Scroll down to the **Security** section. Next to the message about XP[d],
   click **Open Anyway**. (This button only appears for about an hour after
   you tried to open the app; if it is missing, double-click XP[d] again.)
6. Enter your Mac login password and click **OK**, then click **Open**.

macOS remembers this choice: from now on XP[d] opens normally. Each new
version you download needs this once more.

(Older tips such as Control-click › Open no longer work on current macOS;
use the steps above.)

### What you need

- A Mac with **macOS 14 (Sonoma) or later**.
- An **XPPen ACK05 Shortcut Remote** (tested with model ACK05-B, over Bluetooth
  and USB).
- Apple's free **Command Line Tools** (they contain the Swift compiler).
- About 1 GB of free disk space.

### Step 1 — Install Apple's Command Line Tools

Open **Terminal** (Applications › Utilities › Terminal), paste this line and
press Return:

```sh
xcode-select --install
```

Click **Install** in the window that appears and wait for it to finish. If it
says the tools are already installed, go to the next step. (If you already
have Xcode installed, you can skip this step.)

### Step 2 — Download XP[d]

Either:

- **With git** (in Terminal):

  ```sh
  git clone https://github.com/dmssoftres/XP-d-.git
  cd XP-d-
  ```

- **Or without git:** on this GitHub page click **Code › Download ZIP**, unzip
  it, then in Terminal type `cd ` (with a space) and drag the unzipped folder
  onto the Terminal window, and press Return.

### Step 3 — Build and open the app

In Terminal, inside the XP[d] folder, run:

```sh
bash script/build_and_run.sh
```

The first build takes a few minutes. When it finishes, XP[d] opens by itself.
The finished app is in the `dist` folder as **XP[d].app**. You can drag it into
your **Applications** folder and open it from there from now on.

### Step 4 — Remove XPPen's own driver

XPPen's driver and XP[d] cannot both control the remote. Quit the XPPen driver
and stop it from starting at login (System Settings › General › Login Items &
Extensions). You can also uninstall it; XP[d] does not need it.

### Step 5 — Connect the remote

- **Bluetooth:** switch the remote on and pair it in **System Settings ›
  Bluetooth**.
- **Or USB:** plug it in with a data cable.

The status in the top-left of the XP[d] window shows *Bluetooth* (with the
Bluetooth icon) or *USB cable* when it is found.

### Step 6 — Give XP[d] its permissions

macOS asks for these the first time; you can also set them yourself in
**System Settings › Privacy & Security**:

- **Input Monitoring** — required, so XP[d] can read the remote's keys.
- **Accessibility** — needed for keyboard shortcuts, scrolling, typing text and
  window actions.
- **Bluetooth** — allow it when asked (used for driver mode and the battery
  level).

After switching a permission on, quit XP[d] (menu-bar icon › Quit) and open it
again.

### Step 7 — Start using it

Click a key on the picture of the remote and choose its action on the right.
Over Bluetooth every key is recognised automatically. Changes save
automatically; **⌘Z** undoes a change. Use **Profiles** (the stacked-squares
button at the top) to make different layouts, for example one per app.

### Updating to a newer version

In Terminal, inside the XP[d] folder:

```sh
git pull
bash script/build_and_run.sh
```

(If you used Download ZIP, download the new ZIP and repeat Step 3.) Your keys
and profiles are kept. If you copied the app to Applications, copy the new
`dist/XP[d].app` over it.

### If something does not work

- **Keys do nothing or scrolling asks for permission again** after an update:
  run `bash script/build_and_run.sh --reset-permissions`, switch XP[d] on again
  in Accessibility and Input Monitoring, then run
  `bash script/build_and_run.sh --relaunch`.
- **Remote not found:** check it is on and paired, and that XPPen's driver is
  not running.
- **The keys of the remote stop working after XP[d] crashed:** switch the remote
  off and on again.
- More help: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### Uninstalling

Quit XP[d], move **XP[d].app** to the Bin, and remove it from Input Monitoring
and Accessibility in System Settings. Your settings are stored under the name
`com.dmssoftres.xpd`.

## For developers

- Swift 6 package, macOS 14+. Build, ad-hoc sign and launch:
  `./script/build_and_run.sh` (output in `dist/XP[d].app`).
- Run the tests: `swift test`
- Other script modes: `--verify`, `--relaunch`, `--logs`, `--debug`,
  `--reset-permissions`.

## Bluetooth driver mode (distinct keys over Bluetooth)

Over Bluetooth the remote normally sends factory keyboard shortcuts in which
some keys hide others (for example K5 is lost while K10 is held). XP[d]
therefore switches a connected remote into the remote's own **driver mode**,
using the same command XPPen's driver sends. In driver mode every K key, the
wheel and the wheel center arrive as separate signals, so any combination
works. XP[d] recognises the keys automatically; nothing needs to be learned.

- Happens automatically over Bluetooth; USB behaviour is unchanged.
- XP[d] switches the remote back to normal when it quits. If XP[d] crashes,
  switch the remote off and on to restore its normal keys.
- Protocol details: [docs/ACK05_BLUETOOTH_PROTOCOL.md](docs/ACK05_BLUETOOTH_PROTOCOL.md).

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

### Fast Standard F13–F22 preset

Standard **Status & Input** provides one **Use F13–F22 preset** action (or
**Disable F13–F22 preset** when active). It selects the canonical distinct
report-6 keyboard usages F13 through F22 (`0x68` through `0x71`) for K1 through
K10. The `r6` prefix is expected; the usage bytes identify the individual
controls. This is a direct identity mapping, not a timing or key-repeat
heuristic, so XP[d] never guesses K5 from a repeated K10 report.

The preset changes Standard K-input resolution only. It does not rewrite the
active hardware layout, MIDI bindings, MIDI routing, MIDI settings, or held
MIDI/Fn state, and the preset control is not shown in MIDI profiles. The
existing **Advanced manual/live verification** workflow remains available when
the remote's current reports need to be captured instead.

Selecting the preset is not hardware verification. XP[d] does not program the
remote; until one exact report-6 F13–F22 input arrives on the current
connection, Status & Input shows **preset selected; hardware not verified**.
After that live evidence, the status turns green for the connection. Disconnect,
switching into MIDI and back to Standard, or disabling/re-enabling the preset
requires fresh evidence. A single live K press is sufficient for this fast
check; the app does not require a ten-key relearn.

XP[d] does not program the remote. USB is needed only when the remote is not
already emitting F13–F22 and the official XPPen wired **Store/Save** operation
must be used; a data-capable cable is required for that vendor operation. No
undocumented HID programming reports are sent by XP[d]. Over Bluetooth XP[d]
sends only the remote's driver-mode on/off commands (see
[Bluetooth driver mode](#bluetooth-driver-mode-distinct-keys-over-bluetooth)).

## Button gestures

K1–K10 recognize Tap, Hold, and Double from the verified button-down and
generic-release HID stream. Tap waits 0.20 seconds so a second press can become
Double; Hold fires once after 0.50 seconds while the button remains pressed.
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
focus while the field is recording. A plain arrow remains a plain arrow even
when macOS attaches its internal function-key flag. The Globe key is represented
as `fn` only when it is physically held and acts only as a modifier, so it must
be recorded with another key. System-reserved Control-arrow chords are captured
only while the recording field and XP[d] window are active.

XP[d] stores the recorded physical key code with its modifiers and replays one
key-down/key-up chord through macOS when the mapping runs. Accessibility
post-event access is required; physical button input only checks that permission
silently. Older text-only shortcut mappings remain visible but must be
re-recorded before XP[d] will execute them.

For arrows, Home, End, Page Up, Page Down, and forward Delete, playback restores
macOS's internal navigation-function event flag without displaying or storing
`fn`. This lets shortcuts such as `⌃←` behave like the physical keys while
keeping Globe/Fn an independent, explicitly captured modifier.

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
one by itself through the configured threshold makes its Base Tap eligible, but
does not execute it or consume the physical cycle. The modifier remains
layer-eligible until release. If no destination joins, its Base Tap runs once
at release; a quick press/release remains inert. Pressing a destination K while
the modifier remains physically held—before, at, or after the threshold—
suppresses standalone and selects that destination's exact alternate layer.
Exact combinations such as `K3`, `K4`, or `K3 + K4` remain independent.

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
factory report-6 layout and the Standard F13–F22 preset end that cycle with an
empty report 6. A historical programmed F13–F22 layout may instead use the
verified report-2 `F0` bitfield and end it with a zero mask. A release before the
threshold makes a lone modifier inert; a later K is then a new Base cycle.
Empty reports 1, 7, and 9 from unrelated composite collections are ignored and
cannot fake that release. Multiple designated modifiers may be physically
overlapped before one destination to select an exact stacked layer.

K1–K10 raw identities belong to the active device-level hardware layout, not to
individual profiles. In Standard **Status & Input**, **Configure Standard K
layers** captures ten individual controls and then live-verifies K10→K5 and
K5→K10 before committing the layout. A hidden or incorrect composite fails
closed and preserves the prior layout. Live verification is connection-scoped,
so disconnect, relaunch, or layout mutation returns it to pending.

This bulk workflow is absent from MIDI and does not reset or rewrite MIDI
profile data. MIDI Fn routing continues to track partial report-2 presses and
releases without letting report-6 wheel traffic clear the held Fn state.

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

When the matching Shortcut Remote exposes the verified vendor notification, XP[d] shows its exact battery percentage in the window header and menu-bar submenu. The BLE path requires the target's exact PnP identity; apart from the driver-mode on/off commands it only listens. If exact telemetry is absent or invalid, the app shows `Battery unavailable` rather than estimating.

## Development permissions and relaunches

Accessibility and Input Monitoring approval are tied to the app's code signature. This repository uses standard ad-hoc signing because no Apple Development identity is configured on the current Mac. If permissions become stale after a rebuild, run:

```sh
./script/build_and_run.sh --reset-permissions
```

This stops XP[d], resets its Accessibility and Input Monitoring records, opens the Accessibility settings page, and launches the already-built bundle so it can be approved. Approve XP[d] in Accessibility, then use `./script/build_and_run.sh --relaunch` to restart the same bundle without rebuilding or changing its signature. The older `--reset-input-monitoring` mode remains available when only Input Monitoring needs to be reset.

## Buy me a liquid noradrenaline-dopamine rush ☕

XP[d] is free for non-commercial use. If it saves you time and you would like
to say thanks, you can buy me a liquid noradrenaline-dopamine rush at
[Ko-fi](https://ko-fi.com/dmssoftres). It is entirely optional and does not
unlock anything.

## Licence

XP[d] is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE): anyone may use, study, change
and share it for any non-commercial purpose. Selling it, or using it in a
commercial product or service, is not allowed without separate permission.

