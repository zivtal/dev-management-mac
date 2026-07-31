# Dev Reinstaller development rules

Dev Reinstaller is a native macOS 14+ SwiftUI menu-bar utility. It must remain
an `LSUIElement` accessory app: no Dock icon and no ordinary main window.

## Required delivery workflow

- The Xcode project is generated from `project.yml` with XcodeGen.
- Bump the version exactly once for every completed change or fix with
  `scripts/bump-version.sh`.
- Run the unit tests, then run `scripts/build-dmg-unsigned.sh` once.
- The DMG script is the deployment step: it builds Release, verifies the DMG,
  stops the running DevReinstaller process, replaces the copy in `/Applications`,
  and launches the new copy. Do not repeat those deployment actions manually.
- Report the marketing version/build and the DMG/install result.

## Product invariants

- Settings is the home for all current and future preferences.
- English and Hebrew localizations follow the macOS language selection.
- iPhone discovery uses CoreDevice and supports every transport it reports as
  available, including USB and local-network/Wi-Fi connections.
- When work is due, retry discovery every five minutes. Once all work succeeds,
  sleep until the next scheduled reinstall date.
- A project folder may use `install.sh`, but it must never be required; direct
  Xcode project/workspace build and installation is a first-class path.

