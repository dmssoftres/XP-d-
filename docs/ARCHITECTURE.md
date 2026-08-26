# Architecture

## System overview

XP[d] is a local-only SwiftUI macOS application packaged from a SwiftPM executable. It discovers one supported Shortcut Remote through IOKit HID, translates physical inputs into learned controls/gestures, resolves mappings from a central store, executes local actions, and renders both a configuration window and a click-through input overlay.

No backend, database, cloud account, telemetry service, or third-party package dependency is present.

## Components

| Component | Responsibility | Interfaces | Owner |
|---|---|---|---|
| `XPdApp` / `AppDelegate` | Application lifecycle, menu-bar/window setup, initial input permission request | SwiftUI, AppKit, IOKit permission API | Unknown |
| `HIDService` | Match and exclusively seize `10429:514`, fail closed if ownership is unavailable, receive raw reports and values through that manager, retain a bounded connection-local diagnostic trace before semantic filtering, and combine exact HID/BLE battery sources | IOKit HID callbacks/properties | Unknown |
| `ShortcutRemoteBatteryMonitor` | Verify the target BLE PnP identity, enable its two notify-only vendor characteristics, and parse exact battery packets | CoreBluetooth | Unknown |
| `ButtonGestureRecognizer` | Convert K1–K10 down/release reports into mutually exclusive Tap, Hold, and Double events with cancellable timing | Main-actor scheduler seam | Unknown |
| `MappingStore` | Ordered Standard/MIDI profiles, mapping/HID/MIDI state, session Edit/Run state, migration, persistence, imports, selector/Fn routing, action dispatch | SwiftUI observable state, `UserDefaults` | Unknown |
| `ActionRunner` | Execute scrolling, application/window/display actions, keyboard/media events, and explicit Shortcuts/AppleScript/zsh processes; silently preflight routine event-posting/accessibility access | Core Graphics, AppKit, ApplicationServices, Process, IOKit system key definitions | Unknown |
| `MIDIOutputService` | Create Control/Performance virtual sources, encode MIDI 1.0 UMP, track active output, pitch return, cleanup, and exact send-result monitor events | CoreMIDI actor and injectable backend | Unknown |
| Configuration models/document | Codable configuration schema, validation, JSON import/export | Foundation, SwiftUI `FileDocument` | Unknown |
| `ContentView`, `RemoteView`, `MappingInspector`, `KeyboardShortcutCaptureField` | Hardware editor, mapping controls, click-to-record shortcut entry, live status, import/export | SwiftUI, AppKit local events | Unknown |
| Input overlay controller/model/view | Click-through recent-input HUD, hold progress, profile selection, and a narrowly isolated interactive Dismiss panel for ordinary cards | AppKit panels, SwiftUI | Unknown |
| `build_and_run.sh` | Swift build, app-bundle assembly, icon/plist creation, stable ad-hoc signing, launch/debug/log modes | SwiftPM, codesign, macOS tools | Unknown |

## Data flow

Exact VID/PID match → `HIDService` requests exclusive ownership for current and
future devices → on success, Shortcut Remote HID value/report → `MappingStore`
snapshots global modifier flags, F keys, and only configured ordinary keyboard
key codes at K1–K10 button-down → `ButtonGestureRecognizer` → exact persisted
trigger-chord match → mapping resolution → optional same-control Tap application
resolution → `ActionRunner` side effect and input-overlay presentation. A failed
exclusive open routes no production input and is shown as unsafe/unavailable;
there is no passive fallback. Tap waits through the Double window; Hold and
Double suppress Tap. Profile changes, imports, learning, disconnects, and
displaced live controls cancel pending gestures. Inherited Hold/Double
application targets are read at execution time; invalid Tap mappings stop before
side effects.

Configuration UI/profile-manager edits → `MappingStore` → schema-v9 persistence
in `UserDefaults`. One ordered profile collection owns mappings, realm/MIDI
state, Standard titles, modifier designations, and colours. A separate ordered
hardware-layout collection owns device HID bindings and one active layout ID.
Profile creation, renaming, deletion, and switching cannot alter raw device
identity. Versions 2–8 group exact normalized legacy binding sets into named
layouts without discarding divergent sets; the old active profile selects the
initial layout. Portable imports validate all profiles and layouts before one
atomic replacement, and v9 profile JSON omits `hidBindings`.

The Standard-only F13–F22 preset is a separate persisted resolver choice. When
enabled, Standard K-input matching uses the canonical report-6 usages
`0x68...0x71` (F13...F22) for K1...K10; the `r6` report family is expected and
the usage byte provides the distinct identity. The choice does not mutate the
active hardware layout or any MIDI profile payload; only the Standard preset
selection is persisted. MIDI always reads the unchanged device-level layout and
has no preset control or routing branch.
The resolver is direct and deterministic: it does not infer a missing K5 from
timing, repeats, or a K10 snapshot.
Selection alone is not treated as hardware confirmation. The store keeps a
connection-scoped Standard-only evidence flag and turns it on only after an
exact report-6 F13–F22 input is received while the preset is active. Status &
Input remains warning/unverified until then; one live K press is enough for
the fast check, while a ten-key relearn is not required. Disconnect, changing
realms, or disabling/re-enabling the preset clears the flag. XP[d] never
programs the remote through this setting.

Mapping keys include an exact, deterministically encoded set of K-modifier
controls; an empty set is the Base layer. The inspector uses one single-choice
field to select an individual/saved MOD layer and a separate additive builder
to compose active MOD buttons. It keeps separate presentation-only gesture
selections for Base and the selected exact MOD layer. A mapping stores keyboard
modifier flags plus at most one ordinary key condition; the legacy F-key field
remains losslessly supported.

Standard profile activation/modifier enablement → require a non-empty learned HID
binding for every designated K. Missing input fails closed: activation disables
the designation and enablement reports Learn-first guidance without synthesizing
a factory signature. Exact-layer mappings remain saved. Status & Input audits all
learned K report pairs for order-specific masking. Static independence is saved
metadata only and is never presented as current live verification. Clearing a
designated modifier binding cancels pending input, removes the designation in the
same save, and invalidates connection-scoped Standard K verification.

Standard K-layer input → reconcile learned report-6 keyboard snapshots,
including the explicit F13–F22 preset, or the historical programmed report-2
`F0` bitfield until their respective empty/zero release boundary → ignore empty
reports 1, 7, and 9 from the device's unrelated
mouse/digitizer collections → classify every designated K as a modifier and
require exactly one non-designated primary → route Tap/Hold/Double through the
exact modifier-set `MappingKey`. Pending gesture identity includes the primary,
exact K layer, keyboard modifiers, F keys, and configured ordinary keys so only
equivalent presses may form a Double. A destination-first press is reclassified
when a K modifier joins its active K-input cycle. A modifier-only press snapshots the
global local-only standalone threshold (default 0.5 seconds, normalized to
0.2–1.5 in 0.1-second steps). Reaching the threshold only records that the
modifier is eligible for a standalone Base Tap; it does not execute Base, consume
the cycle, or remove layer eligibility. A destination arriving while the
modifier remains physically held—before, at, or after the threshold—suppresses
standalone and selects the exact layer. If no destination participated, release
after the threshold commits Base Tap exactly once; release before the threshold
keeps a quick modifier press inert. Physically overlapped modifier stacks remain
eligible for an exact stacked layer; sequential released modifiers do not merge.
Same-cycle modifier-only stacks and multi-primary cycles remain fail-closed. Press
order is irrelevant within one active rollover cycle. Profile/import/learning/
disconnect/wheel boundaries cancel active state. Physical timing still requires
owner acceptance on the target remote.

Programmed report-2 input is a complete held-button snapshot. Standard routing
reconciles additions and partial releases so releasing a destination while its
modifier remains held completes the layer without rearming the modifier Base.
MIDI routing performs the same state diff, presses Fn before newly added
destinations, and releases destinations before Fn. Report-6 nil/wheel releases
never clear a separate report-2 held set. HID bindings come only from the active
device-level hardware layout and remain unchanged across profile transitions.

Standard `Configure Standard K layers` → copy the active layout into session-only
candidate state → capture K1–K10 in physical order with an explicit release
between buttons → reject malformed, empty, duplicate, composite, mixed-encoding,
masking, and rollover-invalid sets → retain the candidate without saving → require
K10 held then K5 and K5 held then K10 as two live verification sequences. Each
sequence must contain the expected first-control state, a uniquely parsed combined
state, and the final collection release; either partial-release direction is valid.
Only after both orders pass does one transaction replace the ten K bindings. Wheel
and center bindings remain untouched.

The preset is the fast path for a remote already emitting the distinct F13–F22
report-6 usages. Manual/live verification remains the advanced fallback for an
unknown or changed report contract. XP[d] does not program the remote; if the
remote is not emitting F13–F22, a data-capable USB connection is needed only for
the official XPPen wired Store/Save operation. XP[d] never transmits an
undocumented programming report.

The live-verification flag is session-only and connection-scoped. Disconnect,
reload, cancellation, layout/profile replacement, active-layout mutation,
per-control learning, or later contradictory K input clears it. Every failed or
abandoned candidate preserves the prior hardware layout. In particular, if K10
held causes the remote to emit no observable change when K5 is pressed, XP[d]
reports `K10 held hides K5` and cannot infer the hidden input.

The bulk configuration entry point exists only in the Standard inspector and is
also guarded by `MappingStore.activeRealm`. A MIDI-realm invocation is rejected
without clearing active MIDI notes or Fn state, and Standard configuration does
not rewrite MIDI mappings or settings. Layout switching retains its separate,
existing responsibility to reconcile both Standard and MIDI runtime state before
exposing a different device-level binding set.

The owner currently sees K1→F13 through K10→F22 in XPPen's editor and has reported
live report-6 traffic, but the exact ten current payloads and both critical
composites have not yet been captured in this acceptance cycle. Transport does
not select the keyboard encoding, editor labels do not prove emitted reports,
and saved signatures do not prove rollover. Current saved values were deliberately
restored to factory report 6 before the later onboard Store and were never
relearned afterward. The Standard workflow above is the acceptance boundary.

XP[d] currently has no verified HID output path for programming the remote. It
must not guess vendor write reports. If live verification proves that the device
hides a combination, permanent hardware correction remains the XPPen editor's
data-capable wired Save/Store operation unless a proprietary protocol is captured,
replayed safely, and independently verified later.

Raw report callback → normalize a possible report-ID prefix → append the report
to a 12-entry chronological in-memory trace before duplicate/empty semantic
filtering → expose it read-only under Standard `Status & Input`. Connection and
disconnection clear the trace. The trace is not persisted, transmitted, or used
for action routing; it exists to distinguish physical rollover packets from
decoder/state-machine behavior.

Standard mapping inspector → keep Base bound to the left action column → bind
the chosen exact K-modifier set to the right action column → render one complete
`When pressed` chord per action → change the right layer without moving,
overwriting, or deleting other exact-layer mappings. Title, modifier designation,
gesture, and result state remain shared outside the split. Keyboard-shortcut and
trigger-chord capture are mutually exclusive across the two columns so only one
first-responder capture bridge remains active.

Keyboard-shortcut capture → a one-pixel, non-hit-testing AppKit view becomes first responder and, while XP[d] and its recording window are active, installs a session event tap → key-down, key-equivalent, and flags-changed events update an in-view draft for exactly one simultaneous chord (zero or more modifiers plus one physical key) → second mouse click commits structured chord data and its readable display text. The first-responder path consumes navigation keys; the short-lived event tap reaches system-reserved Control-arrow chords before Mission Control. Navigation events' implicit `.function` flag is ignored for storage/display, while physical Globe/Fn is tracked from key-code-63 modifier changes. Losing application/window focus or ending capture removes the tap, and teardown restores the previous responder. Escape, selection/action changes, and view removal cancel the draft without changing either mapping. Remote K-buttons remain mapping triggers and are never recorded as shortcut inputs. `ActionRunner` silently preflights post-event access and, only for a structured chord, posts one matching key-down/key-up pair. Playback restores `.maskSecondaryFn` internally for navigation key codes 115, 116, 117, 119, 121, and 123–126 so generated events match macOS physical navigation semantics without adding visible/stored `fn`; explicit physical Fn still maps to the same event flag. Legacy command-text shortcuts remain visible but are rejected with re-record guidance.

Additional Standard action editor → action-specific text editor or constrained
picker → existing `Mapping.command` persistence field → `ActionRunner` native or
process boundary. macOS Shortcuts run by exact name; AppleScript is passed as one
`osascript -e` argument; shell content is passed as one `zsh -c` argument;
all three remain review-required until locally enabled, and editing, changing
action kind, or importing configuration disarms them without deleting content.
Duplicate process invocations are rejected, four distinct runs may coexist, and
the real process boundary requests graceful termination after 30 seconds. The
original invocation keeps its bounded slot until its termination handler fires;
XP[d] does not signal a potentially recycled integer PID.
media controls post system auxiliary-key down/up events; frontmost-window actions
use AppKit/Accessibility; display sleep uses `pmset displaysleepnow`. Profile
switching stays in `MappingStore` because it mutates profile-owned state, and
profile renames retarget normalized stored switch mappings across every profile.

Show / hide XP[d] mapping → `MappingStore` internal-action dispatch →
`MainWindowController` → retained SwiftUI scene `NSWindow`. A zero-sized
`NSViewRepresentable` registers the scene window without duplicating view state.
Only a visible key window in the active application hides; minimized,
ordered-out/closed, and background states deminiaturize or show, focus, and
activate the retained window. This app-owned path never enters `ActionRunner`'s
Accessibility-based external-window mutation.

Header Edit/Run control → session-only `MappingStore.isRunMode` →
`MainWindowController` focus transition. Run keeps all HID gesture resolution,
mapped actions, scrolling, MIDI, overlays, and remote profile/workspace gestures
active, but skips only routine HID-driven `selectedControl` writes. The controller
keeps the retained editor visible without making it key and activates the most
recently observed non-XP[d] application. Missing or failed external activation
leaves Edit active; no Run state enters persistence or exported configuration.

Send frontmost window to screen mapping → hardware identity encoded in the
existing `Mapping.command` → live `NSScreen` resolution → frontmost focused/main
AX window → read current size → center an AX position inside the destination's
visible frame expressed in Core Graphics coordinates. Exact identity wins;
serial-backed matching tolerates a changed transient unit number only when it
resolves uniquely. Disconnected or ambiguous destinations fail closed, the
window is never resized, and screen-list changes refresh the editor picker.

Trigger-chord capture → fixed destination K plus the selected exact K layer →
local modifier/ordinary-key monitor and temporary designated-K capture handler →
in-view draft with zero or more K modifiers, zero or more keyboard modifiers,
and at most one ordinary key → second mouse click commits optional keyboard
conditions and/or navigates to the selected layer. Capture consumes remote input
before normal routing and never retargets the destination. At runtime keyboard
state sampled on destination down must exactly match before overlay or action
effects; the snapshot remains associated with the later Tap/Hold/Double result.

MIDI-realm HID input → `MappingStore` primary/Fn routing and session offsets →
`MIDIOutputService` → independent `XP[d] Control` or `XP[d] Performance`
virtual source. The service tracks origin/port/channel/note state so release,
profile/import/disconnect/Panic/shutdown boundaries can send matching Note Off,
All Notes Off, and centered Pitch Bend messages.

Every actual send attempt also emits one transient monitor event back to the
main-actor store. The MIDI inspector keeps only the newest 100 events and can
copy or clear them; monitor history is diagnostic state and is never persisted.

Wheel-center hold → open selector with current profile order → wheel rotation
updates only the pending highlight → center release activates the highlighted
profile and loads its mappings while retaining the active hardware layout.
Adding, renaming, deleting, or importing profiles closes stale selector state.

Matching HID connection → BLE PnP read/verification → notify-only FFE0/0002 plus FFE0/0003 subscription → validated `02 F2 01 <percent>` packet → `HIDService` battery state → header and menu-bar UI. Disconnect, identity mismatch, Bluetooth loss, or invalid data clears/withholds the BLE value.

The build script compiles `XPd`, assembles `dist/XP[d].app`, creates its Info.plist, copies the icon, applies a stable designated requirement for `com.dmssoftres.xpd`, and optionally launches or verifies the process.

## Trust boundaries

- macOS Input Monitoring consent gates remote input observation.
- Accessibility/event-posting consent gates synthetic scrolling and window manipulation.
- HID reports are untrusted hardware input and must be matched/decoded narrowly.
- Private BLE notifications are untrusted peripheral input; require exact PnP identity, packet signature, and 0...100 range, and never write undocumented vendor characteristics.
- Imported JSON and user-entered commands are untrusted data; imports require complete validation and commands execute only through explicit mappings.
- TCC reset modes mutate the user's privacy settings and remain manual recovery operations.

## Failure modes

- Remote absent or mismatched: HID manager opens but no supported device connects.
- Exclusive HID ownership unavailable: keep learning/mapping input disabled and
  warn that factory input is not blocked; never continue with passive routing.
- Privacy approval stale after rebuild: the app may connect or post events incorrectly until the stable signed bundle is approved/relaunched.
- Invalid import: reject atomically without replacing any in-memory or persisted profile state.
- Unknown/changed HID report: learning or mapped control resolution fails; capture evidence before changing decoding.
- Empty composite report 1, 7, or 9 during a K hold: ignore it. Factory K input
  releases only on empty report 6; programmed report-2 input releases only on
  its verified `F0` zero mask.
- Missing release or conflicting live-button reports: cancel the displaced/pending gesture rather than execute an ambiguous action.
- Standard K configuration cannot observe K5 while K10 is held: reject the
  candidate, retain the prior layout, leave live verification false, and direct
  hardware correction to the verified vendor Store path. Never synthesize K5 or
  transmit an undocumented programming report.
- Missing/mismatched BLE identity or notification: retain an exact HID property if available; otherwise show battery unavailable rather than estimating.
- Wheel-center report changes or loses its device-specific standalone empty report-6 distinction: selector confirmation may regress and requires controlled real-hardware recapture.
- Action target unavailable or permission denied: report a structured action failure without corrupting mappings. Existing application targets are unhidden/restored where permitted, directly activated, and asynchronously verified as foreground; a failed or ineffective direct activation makes one same-path `NSWorkspace` reopen attempt without creating another instance.
- Inherited Hold/Double target invalid: show the Tap validation failure and do not invoke `ActionRunner`.
- Keyboard-shortcut capture interrupted: remove the temporary first-responder bridge, restore normal focus where possible, and discard the in-memory chord draft without writing into the current or newly selected mapping.
- CoreMIDI source creation/send failure: keep profile state intact, report the
  affected port, and retain failed live/toggle state so cleanup can retry.
- Unverified physical Fn rollover: do not substitute a latch or claim the
  software routing seam proves target-device behavior.

## Architecture references

- `Package.swift`
- `Sources/XPd/Services/HIDService.swift`
- `Sources/XPd/Stores/MappingStore.swift`
- `Sources/XPd/Services/ActionRunner.swift`
- `Sources/XPd/Services/MIDIOutputService.swift`
- `Sources/XPd/Models/MIDITypes.swift`
- `Sources/XPd/Models/XPdConfiguration.swift`
- `script/build_and_run.sh`
- `.llm/DECISIONS.md`
