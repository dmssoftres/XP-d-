# Architecture

## System overview

XP[d] is a local-only SwiftUI macOS application packaged from a SwiftPM executable. It discovers one supported Shortcut Remote through IOKit HID, translates physical inputs into learned controls/gestures, resolves mappings from a central store, executes local actions, and renders both a configuration window and a click-through input overlay.

No backend, database, cloud account, telemetry service, or third-party package dependency is present.

## Components

| Component | Responsibility | Interfaces | Owner |
|---|---|---|---|
| `XPdApp` / `AppDelegate` | Application lifecycle, menu-bar/window setup, initial input permission request | SwiftUI, AppKit, IOKit permission API | Unknown |
| `HIDService` | Match `10429:514`, manage HID lifecycle, publish input reports/wheel values, and combine exact HID/BLE battery sources | IOKit HID callbacks/properties | Unknown |
| `ShortcutRemoteBatteryMonitor` | Verify the target BLE PnP identity, enable its two notify-only vendor characteristics, and parse exact battery packets | CoreBluetooth | Unknown |
| `ButtonGestureRecognizer` | Convert K1–K10 down/release reports into mutually exclusive Tap, Hold, and Double events with cancellable timing | Main-actor scheduler seam | Unknown |
| `MappingStore` | Ordered Standard/MIDI profiles, mapping/HID/MIDI state, migration, persistence, imports, selector/Fn routing, action dispatch | SwiftUI observable state, `UserDefaults` | Unknown |
| `ActionRunner` | Execute scrolling, application actions, and captured keyboard chords; silently preflight routine event-posting access | Core Graphics, AppKit, ApplicationServices, process APIs | Unknown |
| `MIDIOutputService` | Create Control/Performance virtual sources, encode MIDI 1.0 UMP, track active output, pitch return, cleanup, and exact send-result monitor events | CoreMIDI actor and injectable backend | Unknown |
| Configuration models/document | Codable configuration schema, validation, JSON import/export | Foundation, SwiftUI `FileDocument` | Unknown |
| `ContentView`, `RemoteView`, `MappingInspector`, `KeyboardShortcutCaptureField` | Hardware editor, mapping controls, click-to-record shortcut entry, live status, import/export | SwiftUI, AppKit local events | Unknown |
| Input overlay controller/model/view | Click-through recent-input HUD, hold progress, profile selection | AppKit panel, SwiftUI | Unknown |
| `build_and_run.sh` | Swift build, app-bundle assembly, icon/plist creation, stable ad-hoc signing, launch/debug/log modes | SwiftPM, codesign, macOS tools | Unknown |

## Data flow

Shortcut Remote HID value/report → `HIDService` → `MappingStore` snapshots global modifier flags at K1–K10 button-down → `ButtonGestureRecognizer` → exact persisted remote-trigger modifier match → mapping resolution → optional same-control Tap application resolution → `ActionRunner` side effect and input-overlay presentation. Tap waits through the Double window; Hold and Double suppress Tap. Profile changes, imports, learning, disconnects, and displaced live controls cancel pending gestures. Inherited Hold/Double application targets are read at execution time; invalid Tap mappings stop before side effects.

Configuration UI/profile-manager edits → `MappingStore` → one ordered version-6 profile collection in `UserDefaults`. Standard K1–K10 titles and designated K-modifier controls are profile-scoped and excluded from MIDI profiles. Mapping keys include an exact, deterministically encoded set of K-modifier controls; an empty set is the Base layer. Renaming a non-Global profile replaces its name identity atomically while preserving order, realm, mappings, HID bindings, button titles, modifier designations, active selection, and remembered workspace targets. Version-2 fixed and version-3 dynamic persistence migrate to Standard profiles; version 4 gains empty title collections and version 5 gains empty K-modifier state. Export builds a complete ordered JSON document; v2–v5 exports upgrade on decode, and imports validate realms, remembered profiles, typed MIDI values, exact mapping layers, bindings, and Standard metadata before one replacement.

Standard K-layer input → accumulate K reports until the generic HID release boundary → classify every designated K as a modifier and require exactly one non-designated primary → route Tap/Hold/Double through the exact modifier-set `MappingKey`. Pending gesture identity includes the primary, exact K layer, keyboard modifiers, and F keys so only equivalent presses may form a Double; a primary-first press is reclassified when a K modifier joins its active cycle. A single designated modifier released alone executes its Base Tap mapping; modifier-only stacks and multi-primary cycles are consumed. Press order is irrelevant within the cycle. Profile/import/learning/disconnect/wheel boundaries cancel the accumulated cycle. Physical rollover and the target device's post-release report behavior remain manual acceptance points because the current HID stream exposes only one generic release boundary.

Standard mapping inspector → keep Base bound to the left action column → bind
the chosen exact K-modifier set to the right action column → keep title,
modifier designation, gesture, and result state shared outside the split.
Keyboard-shortcut and remote-trigger capture are mutually exclusive across the
two columns so only one local event monitor/capture handler remains active.

Keyboard-shortcut capture → local AppKit key-down/flags-changed monitor → in-view draft for exactly one simultaneous chord (zero or more modifiers plus one physical key) → second mouse click commits structured chord data and its readable display text. Escape, selection/action changes, and view removal cancel the draft without changing either mapping. Remote K-buttons remain mapping triggers and are never recorded as shortcut inputs. `ActionRunner` silently preflights post-event access and, only for a structured chord, posts one matching key-down/key-up pair; legacy command-text shortcuts remain visible but are rejected with re-record guidance.

Remote-trigger capture → local modifier/function-key monitor plus a temporary
`MappingStore` K1–K10 capture handler → in-view draft combining modifiers,
one held F1–F12 key, and the captured remote special key → second mouse click
writes remote trigger data to that button's selected gesture mapping and selects
the captured button. The handler consumes capture input before normal routing.
At runtime global modifier and F-key state sampled on K-button down must exactly
match before overlay or action effects; the snapshot remains associated with the
later Tap/Hold/Double result.

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
- Privacy approval stale after rebuild: the app may connect or post events incorrectly until the stable signed bundle is approved/relaunched.
- Invalid import: reject atomically without replacing any in-memory or persisted profile state.
- Unknown/changed HID report: learning or mapped control resolution fails; capture evidence before changing decoding.
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
