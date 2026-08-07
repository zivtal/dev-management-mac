# Development Management development rules

Development Management is a native macOS 14+ SwiftUI menu-bar utility. It must remain
an `LSUIElement` accessory app: no Dock icon and no ordinary main window.

## Required delivery workflow

- The Xcode project is generated from `project.yml` with XcodeGen.
- Bump the version exactly once for every completed change or fix with
  `scripts/bump-version.sh`.
- Run the unit tests, then run `scripts/build-dmg-unsigned.sh` once.
- The DMG script is the deployment step: it builds Release, verifies the DMG,
  stops the running Development Management process, replaces the copy in `/Applications`,
  and launches the new copy. Do not repeat those deployment actions manually.
- After the tests and DMG deployment succeed, commit the completed changes and
  push the current branch to `origin`.
- Report the marketing version/build and the DMG/install result.

## Product invariants

- Settings is the home for all current and future preferences.
- English and Hebrew localizations follow the macOS language selection.
- iPhone discovery uses CoreDevice and supports every transport it reports as
  available, including USB and local-network/Wi-Fi connections.
- Device targeting is configured separately for each managed application. Show
  only connected iPhone and iPad families supported by the selected Xcode scheme.
- A managed macOS application targets the local Mac. Direct installation builds
  the selected scheme, creates and verifies a DMG, stops an existing running copy,
  atomically replaces it in `/Applications`, and launches the new copy.
- Pausing an application preserves its device selections but blocks automatic,
  manual, and Install All work until it is resumed. Work already in progress may
  finish.
- Every application row in the menu-bar popover provides a direct Play/Pause
  control for resuming or pausing future installations.
- Settings opens at no less than 80% of the available screen height.
- Application build controls and device-selection guidance remain fixed; only
  the compatible-device rows scroll when their list exceeds the available space.
- When work is due, retry discovery every five minutes. Once all work succeeds,
  sleep until the next scheduled reinstall date.
- A project folder may use `install.sh`, but it must never be required; direct
  Xcode project/workspace build and installation is a first-class path.
