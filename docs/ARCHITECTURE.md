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
| `MappingStore` | Ordered dynamic profiles, active-profile mappings/HID bindings, migration, persistence, imports, selector state, action dispatch | SwiftUI observable state, `UserDefaults` | Unknown |
| `ActionRunner` | Execute mapped shortcuts, scrolling, app actions, and commands; permission preflight/settings | Core Graphics, AppKit, ApplicationServices, process APIs | Unknown |
| Configuration models/document | Codable configuration schema, validation, JSON import/export | Foundation, SwiftUI `FileDocument` | Unknown |
| `ContentView`, `RemoteView`, `MappingInspector` | Hardware editor, mapping controls, live status, import/export | SwiftUI | Unknown |
| Input overlay controller/model/view | Click-through recent-input HUD, hold progress, profile selection | AppKit panel, SwiftUI | Unknown |
| `build_and_run.sh` | Swift build, app-bundle assembly, icon/plist creation, stable ad-hoc signing, launch/debug/log modes | SwiftPM, codesign, macOS tools | Unknown |

## Data flow

Shortcut Remote HID value/report → `HIDService` → `MappingStore` control/gesture resolution → persisted mapping lookup → `ActionRunner` side effect and input-overlay presentation.

Configuration UI/profile-manager edits → `MappingStore` → one ordered version-3 profile collection in `UserDefaults`. Version-2 fixed-profile persistence migrates in Global/Finder/Logic Pro order; older shared mappings and HID bindings migrate into Global. Export builds a complete ordered JSON document; version-2 exports upgrade on decode, and imports validate Global, names, active profile, mappings, and bindings before one replacement.

Wheel center → open persistent selector with current profile order → wheel rotation updates only the pending highlight → second center press activates the highlighted profile and loads its mappings/HID bindings. Adding, deleting, or importing profiles closes stale selector state.

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
- Missing/mismatched BLE identity or notification: retain an exact HID property if available; otherwise show battery unavailable rather than estimating.
- Wheel-center report changes or loses its device-specific standalone empty report-6 distinction: selector confirmation may regress and requires controlled real-hardware recapture.
- Action target unavailable or permission denied: report a structured action failure without corrupting mappings.

## Architecture references

- `Package.swift`
- `Sources/XPd/Services/HIDService.swift`
- `Sources/XPd/Stores/MappingStore.swift`
- `Sources/XPd/Services/ActionRunner.swift`
- `Sources/XPd/Models/XPdConfiguration.swift`
- `script/build_and_run.sh`
- `.llm/DECISIONS.md`
