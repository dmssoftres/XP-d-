# Troubleshooting

## XP[d] repeatedly asks for scrolling or Accessibility access

- **Observed behavior:** scrolling fails or macOS approval appears stale after rebuilding.
- **Likely causes:** the installed/running bundle differs from the approved signed bundle, or existing TCC records predate the stable designated requirement.
- **Verification:** confirm bundle ID/signature, launch the already-built `dist/XP[d].app`, and use silent permission preflight rather than prompting during wheel events.
- **Fix:** use the explicit `./script/build_and_run.sh --reset-permissions` recovery flow once, approve the built bundle, then relaunch the same bundle with `--relaunch`.
- **Do not:** reset TCC automatically, prompt from every wheel event, or rebuild between approval and verification.
- **Related files/decisions:** `README.md`, `script/build_and_run.sh`, `Sources/XPd/Services/ActionRunner.swift`

## Shortcut Remote does not connect

- **Observed behavior:** the app runs but reports no supported HID device.
- **Likely causes:** remote disconnected, Input Monitoring unavailable, or device identity differs from vendor ID `10429` / product ID `514`.
- **Verification:** confirm Bluetooth connection and macOS Input Monitoring approval; inspect HID logs without broadening device matching.
- **Fix:** reconnect and approve the existing signed app, then relaunch it.
- **Do not:** match all HID devices or log unrelated system input.
- **Related files/decisions:** `README.md`, `Sources/XPd/Services/HIDService.swift`

## Connected remote shows Battery unavailable

- **Observed behavior:** HID connection works, but no percentage appears.
- **Likely causes:** Bluetooth access is denied/off, the BLE PnP identity differs, or the verified vendor notifications are unavailable.
- **Verification:** inspect privacy-safe `com.dmssoftres.xpd` / `Battery` logs for state, identity, and subscription milestones.
- **Fix:** enable Bluetooth for the existing signed app and reconnect/relaunch; do not reset unrelated TCC permissions automatically.
- **Do not:** estimate charge, weaken identity/packet validation, or send undocumented BLE writes.

## Imported configuration is rejected

- **Observed behavior:** import reports failure and current mappings remain unchanged.
- **Likely causes:** invalid JSON, unsupported schema version, missing/unknown/duplicate profiles, duplicate mapping keys, or invalid HID bindings.
- **Verification:** inspect the structured import result and validate against `XPdConfiguration` requirements.
- **Fix:** correct the exported JSON or migrate the schema deliberately with tests.
- **Do not:** partially apply invalid content or bypass validation.
- **Related files/decisions:** `Sources/XPd/Models/XPdConfiguration.swift`, `Tests/XPdTests/XPdConfigurationTests.swift`

## Wheel-center profile selector does not open

- **Observed behavior:** the first center press does not keep the profile selector visible, or the second press does not activate the highlighted profile.
- **Likely causes:** the device's standalone empty report 6 is no longer distinguished from release reports, or the active profile lost its wheel-center/rotation bindings.
- **Verification:** confirm the active profile contains `wheel:center`, `wheel:+`, and `wheel:-`; then capture controlled reports for center, rotation, and releases.
- **Fix:** restore the profile's default wheel bindings or correct report decoding only from new device evidence.
- **Do not:** treat every empty/release report as center or change device matching speculatively.
- **Related files/decisions:** `README.md`, `Sources/XPd/Services/HIDService.swift`
