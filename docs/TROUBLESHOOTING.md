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

## Imported configuration is rejected

- **Observed behavior:** import reports failure and current mappings remain unchanged.
- **Likely causes:** invalid JSON, unsupported schema content, duplicate/missing mappings, or out-of-range settings.
- **Verification:** inspect the structured import result and validate against `XPdConfiguration` requirements.
- **Fix:** correct the exported JSON or migrate the schema deliberately with tests.
- **Do not:** partially apply invalid content or bypass validation.
- **Related files/decisions:** `Sources/XPd/Models/XPdConfiguration.swift`, `Tests/XPdTests/XPdConfigurationTests.swift`

## Wheel-center press cannot be mapped

- **Observed behavior:** pressing the center does not produce a unique learnable event.
- **Likely causes:** current hardware/driver path exposes no distinct HID report.
- **Verification:** capture controlled raw HID evidence while isolating keyboard-release and wheel events.
- **Fix:** Unknown until a unique signal or safe alternate integration is verified.
- **Do not:** infer center presses from ambiguous empty/release reports in the production app.
- **Related files/decisions:** `README.md`, `Sources/XPd/Services/HIDService.swift`
