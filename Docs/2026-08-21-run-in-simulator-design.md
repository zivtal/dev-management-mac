# Run in Simulator — design

Approved 2026-08-21. Adds a per-application "Run in Simulator" action to the
menu-bar popover that opens a per-project window with live simulator controls,
mirroring `trip-flow-ios/run-emulator.sh` natively.

## Feature summary

- Per-app row button (iOS apps only) opens a per-project simulator session
  window.
- Window controls: simulator device picker, GPS latitude/longitude, simulated
  date and time (Debug-only env-var convention), app language, and an editable
  env-var name for the simulated clock (default `<SCHEME>_DEBUG_NOW`
  uppercased).
- Session cycle: boot device → set location → build → install → launch → watch
  sources and auto rebuild/relaunch on changes (FSEvents, ~0.5 s debounce; one
  queued follow-up rebuild if changes land mid-build).
- Live semantics: GPS applies instantly (`simctl location set`); date/time,
  language, and env-var name relaunch the app without rebuilding; a device
  change boots the new simulator, installs the existing build, and relaunches.
- Stop or closing the window ends watching; the simulator and app keep running
  (Ctrl-C parity with the script).

## Components

1. **Model** — `ManagedProject.simulatorRunSettings: SimulatorRunSettings?`
   (Codable, optional, backward compatible): `deviceUDID`, `latitude`,
   `longitude`, `simulatedDate` (yyyy-MM-dd), `simulatedTime` (HH:mm),
   `language`, `debugNowVariableName`. Persisted via existing `state.json`.
2. **SimulatorService** (new, takes `ProcessRunning`): `listDevices`, `boot`,
   `waitUntilBooted`, `openSimulatorApp`, `install`, `terminate`,
   `launch(udid:bundleID:arguments:environment:)`, `setLocation`.
   `SimulatorDevice` + JSON parsing move to `Sources/Models/`;
   `AppStorePublishingService` is refactored to the shared code. Language is
   passed as `-AppleLanguages "(code)"` launch arguments; simulated now is
   `SIMCTL_CHILD_<VAR>` in the launch environment, formatted like the script
   (date-only, or ISO datetime with the Mac's UTC offset).
3. **Build path** — `InstallationService.buildForSimulator(project:
   simulatorUDID:derivedDataURL:eventHandler:)` reusing XcodeGen prep, scheme
   script stripping, version-preservation validation, and built-app location,
   with destination `platform=iOS Simulator,id=<udid>`,
   `CODE_SIGNING_ALLOWED=NO`, and no signing-team flags. Persistent derived
   data per project under
   `~/Library/Application Support/DevManagement/SimulatorDerivedData/<projectID>/`.
4. **SimulatorSessionController** — per-project, owned by `AppModel`
   (`simulatorSessions: [UUID: …]`); publishes phase, build count, and log
   lines. FSEvents watch of the project folder ignoring `.git`, derived data,
   `*.md`, `.DS_Store`.
5. **UI** — 5th row button (iOS apps only); action column 98 → 118 pt, popover
   615/715 → 635/735 (`MenuBarLayoutPolicyTests` updated). Session window
   (~720×640 cascading panel, publishing-presenter pattern): device picker
   filtered by the scheme's supported families (default: booted device, else
   newest iPhone), GPS fields with Apply, optional date/time pickers, env-var
   name field, language picker from `ProjectLocalizationDiscoveryService` plus
   "Simulator default", Run/Stop and Rebuild Now, status line, scrolling log.
6. **Localization** — all new strings in `en.lproj` and `he.lproj`.
7. **Tests** — simulator JSON parsing, simulator xcodebuild argv, launch
   args/env building (language array, `SIMCTL_CHILD_` var, date/time formats
   incl. UTC offset), settings round-trip, layout policy, watch-path exclusion
   rules.

## Invariants honored

- Managed apps are built directly with Xcode; scheme pre/post actions are
  stripped; no repo `install.sh`.
- Simulator builds must preserve the app's marketing version and build number.
- Delivery: bump version once, run tests, `build-dmg-unsigned.sh`, commit and
  push, report version + install result.
