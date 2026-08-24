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

Configuration UI/profile-manager edits → `MappingStore` → one ordered version-8 profile collection in `UserDefaults`. Standard K1–K10 titles, designated K-modifier controls, and modifier colours are profile-scoped and excluded from MIDI profiles. Mapping keys include an exact, deterministically encoded set of K-modifier controls; an empty set is the Base layer. The inspector uses one single-choice field to select an individual/saved MOD layer and a separate additive builder to compose active MOD buttons. It also keeps separate presentation-only gesture selections for Base and the currently selected exact MOD layer; every editor operation receives its explicit gesture and layer identity. A mapping stores keyboard modifier flags plus at most one ordinary key condition; the legacy F-key field remains losslessly supported. Renaming a non-Global profile replaces its name identity atomically while preserving order, realm, mappings, HID bindings, button titles, modifier designations, colours, active selection, and remembered workspace targets. Versions 2–7 migrate without dropping supported data; v7 modifiers migrate to Orange. Imports validate realms, remembered profiles, typed MIDI values, exact mapping layers, keyboard trigger keys, bindings, and Standard metadata before one replacement.

Standard profile activation/modifier enablement → require a non-empty learned HID
binding for every designated K. Missing input fails closed: activation disables
the designation and enablement reports Learn-first guidance without synthesizing
a factory signature. Exact-layer mappings remain saved. Status & Input audits all
learned K report pairs for order-specific masking; this is inferred compatibility,
not a live hardware claim. Clearing a designated modifier binding cancels pending
input and removes the designation in the same save.

Standard K-layer input → accumulate either factory report-6 keyboard states or
the verified programmed report-2 `F0` bitfield until their respective empty/zero
release boundary → ignore empty reports 1, 7, and 9 from the device's unrelated
mouse/digitizer collections → classify every designated K as a modifier and
require exactly one non-designated primary → route Tap/Hold/Double through the
exact modifier-set `MappingKey`. Pending gesture identity includes the primary,
exact K layer, keyboard modifiers, F keys, and configured ordinary keys so only
equivalent presses may form a Double. A destination-first press is reclassified
when a K modifier joins its active K-input cycle. A modifier-only press snapshots the
global local-only standalone threshold (default 0.5 seconds, normalized to
0.2–1.5 in 0.1-second steps). Expiry immediately executes Base Tap when exactly
one modifier remains physically held and no primary participated, then consumes
the rest of that K-input cycle. A destination arriving while the modifier is
still physically held and strictly before expiry cancels standalone and selects
the exact layer. The collection's release state before expiry makes a lone modifier inert;
the next K starts a new Base cycle. Physically overlapped modifier stacks remain
eligible for an exact stacked layer; sequential released modifiers do not merge.
Same-cycle modifier-only stacks and multi-primary cycles remain consumed. Press
order is irrelevant within one active rollover cycle. Profile/import/learning/
disconnect/wheel boundaries cancel active state. Physical timing still requires
owner acceptance on the target remote.

Programmed report-2 input is a complete held-button snapshot. Standard routing
reconciles additions and partial releases so releasing a destination while its
modifier remains held completes the layer without rearming the modifier Base.
MIDI routing performs the same state diff, presses Fn before newly added
destinations, and releases destinations before Fn. Report-6 nil/wheel releases
never clear a separate report-2 held set. HID bindings remain profile-specific.

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
local event monitor/capture handler remains active.

Keyboard-shortcut capture → local AppKit key-down/flags-changed monitor → in-view draft for exactly one simultaneous chord (zero or more modifiers plus one physical key) → second mouse click commits structured chord data and its readable display text. Escape, selection/action changes, and view removal cancel the draft without changing either mapping. Remote K-buttons remain mapping triggers and are never recorded as shortcut inputs. `ActionRunner` silently preflights post-event access and, only for a structured chord, posts one matching key-down/key-up pair; legacy command-text shortcuts remain visible but are rejected with re-record guidance.

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

Wheel-center hold → open selector with current profile order → wheel rotation updates only the pending highlight → center release activates the highlighted profile and loads its mappings/HID bindings. Adding, renaming, deleting, or importing profiles closes stale selector state.

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
- Missing/mismatched BLE identity or notification: retain an exact HID property if available; otherwise show battery unavailable rather than estimating.
- Wheel-center report changes or loses its device-specific standalone empty report-6 distinction: selector confirmation may regress and requires controlled real-hardware recapture.
- Action target unavailable or permission denied: report a structured action failure without corrupting mappings. Existing application targets are unhidden/restored where permitted, directly activated, and asynchronously verified as foreground; a failed or ineffective direct activation makes one same-path `NSWorkspace` reopen attempt without creating another instance.
- Inherited Hold/Double target invalid: show the Tap validation failure and do not invoke `ActionRunner`.
- Keyboard-shortcut capture interrupted: remove the local event monitor and discard the in-memory chord draft without writing into the current or newly selected mapping.
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
