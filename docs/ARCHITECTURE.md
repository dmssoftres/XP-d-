# Architecture

## System overview

XP[d] is a local-only SwiftUI macOS application packaged from a SwiftPM executable. It discovers one supported Shortcut Remote through IOKit HID, translates physical inputs into learned controls/gestures, resolves mappings from a central store, executes local actions, and renders both a configuration window and a click-through input overlay.

No backend, database, cloud account, telemetry service, or third-party package dependency is present.

## Components

| Component | Responsibility | Interfaces | Owner |
|---|---|---|---|
| `XPdApp` / `AppDelegate` | Application lifecycle, menu-bar/window setup, initial input permission request | SwiftUI, AppKit, IOKit permission API | Unknown |
| `HIDService` | Match `10429:514`, manage HID lifecycle, publish input reports/wheel values, and expose optional verified battery percentage | IOKit HID callbacks/properties | Unknown |
| `MappingStore` | Central active-profile state, independent profile mappings/HID bindings, migration, persistence, imports, action dispatch | SwiftUI observable state, `UserDefaults` | Unknown |
| `ActionRunner` | Execute mapped shortcuts, scrolling, app actions, and commands; permission preflight/settings | Core Graphics, AppKit, ApplicationServices, process APIs | Unknown |
| Configuration models/document | Codable configuration schema, validation, JSON import/export | Foundation, SwiftUI `FileDocument` | Unknown |
| `ContentView`, `RemoteView`, `MappingInspector` | Hardware editor, mapping controls, live status, import/export | SwiftUI | Unknown |
| Input overlay controller/model/view | Click-through recent-input HUD, hold progress, profile selection | AppKit panel, SwiftUI | Unknown |
| `build_and_run.sh` | Swift build, app-bundle assembly, icon/plist creation, stable ad-hoc signing, launch/debug/log modes | SwiftPM, codesign, macOS tools | Unknown |

## Data flow

Shortcut Remote HID value/report → `HIDService` → `MappingStore` control/gesture resolution → persisted mapping lookup → `ActionRunner` side effect and input-overlay presentation.

Configuration UI edits → active profile in `MappingStore` → one version-2 profile collection in `UserDefaults`. A one-time migration places legacy shared mappings and HID bindings into Global. Export builds a complete three-profile JSON document; import validates the exact profile set and every profile's entries before one replacement.

Wheel center → open persistent selector → wheel rotation updates only the pending highlight → second center press activates the highlighted profile and loads its mappings/HID bindings.

The build script compiles `XPd`, assembles `dist/XP[d].app`, creates its Info.plist, copies the icon, applies a stable designated requirement for `com.dmssoftres.xpd`, and optionally launches or verifies the process.

## Trust boundaries

- macOS Input Monitoring consent gates remote input observation.
- Accessibility/event-posting consent gates synthetic scrolling and window manipulation.
- HID reports are untrusted hardware input and must be matched/decoded narrowly.
- Imported JSON and user-entered commands are untrusted data; imports require complete validation and commands execute only through explicit mappings.
- TCC reset modes mutate the user's privacy settings and remain manual recovery operations.

## Failure modes

- Remote absent or mismatched: HID manager opens but no supported device connects.
- Privacy approval stale after rebuild: the app may connect or post events incorrectly until the stable signed bundle is approved/relaunched.
- Invalid import: reject atomically without replacing any in-memory or persisted profile state.
- Unknown/changed HID report: learning or mapped control resolution fails; capture evidence before changing decoding.
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
