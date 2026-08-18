# Development Management

Development Management is a native macOS menu-bar utility that periodically rebuilds
and reinstalls locally developed iOS applications on paired iPhones and iPads, and
macOS applications on the local Mac. It supports development-signed mobile apps
whose installed builds need renewal as well as repeatable local Mac deployments.

The app does not try to inspect a provisioning profile's expiration date.
Instead, it records each successful installation and reinstalls after a
configurable number of days.

## Product principles

- Native SwiftUI application for macOS 14 or newer.
- Menu-bar-only `LSUIElement` accessory app: no Dock icon and no ordinary main
  window.
- Settings is the home for every preference and management surface.
- English and Hebrew follow the language selected by macOS.
- Device discovery is based on Xcode's CoreDevice tooling and accepts every
  available transport, including USB and local-network/Wi-Fi connections.
- Installation schedules are tracked independently for every application and
  every iPhone or iPad.
- A project-level `install.sh` is supported but never required. Direct Xcode
  build and device installation is a first-class workflow.
- When installation work is pending, discovery is retried every five minutes.
  After all work succeeds, the app sleeps until the next scheduled date.

## Features

- Automatic reinstall interval from 1 to 30 days; the default is 3 days.
- Automatic installed-version checks that immediately update a connected
  selected device when its app is missing or older than the source version.
- Immediate install for one application or all enabled applications.
- Background `Install All Now` queue that waits for a device if necessary.
- Project and workspace discovery with shared scheme and configuration
  selection.
- Direct `xcodebuild` build, signing, provisioning, and CoreDevice installation.
- Direct macOS build, verified DMG creation, running-process shutdown, atomic
  replacement in `/Applications`, and relaunch.
- Optional custom installation through a root-level `install.sh`.
- iPhone, iPad, and Apple Watch discovery; iOS and iPadOS devices are install
  targets, while Apple Watch is displayed as a companion device.
- Per-application device selection in Settings, persisted by application and
  device UDID.
- Per-application pause and resume. Paused apps are excluded from automatic,
  manual, and Install All installation paths while retaining their device
  selections and installation history.
- Automatic iPhone/iPad compatibility detection from the selected Xcode
  scheme's `TARGETED_DEVICE_FAMILY` build setting.
- USB hot-plug monitoring and manual device refresh.
- Background monitoring starts with the menu-bar app; opening its popover or
  Settings is not required for automatic checks.
- Application version, build number, icon, schedule, and last-install status.
- A live, copyable installation log opened by clicking the progress card.
- A persistent activity log with command output and error details.
- A notification after every successful installation, including the app,
  device, model, connection type, and discovered app icon.
- Launch at login, enabled by default on first run.
- One-click iOS publishing that prepares metadata and screenshots, creates the
  App Store version, ensures the exact build is available to internal
  TestFlight testers, uploads project-owned review attachments, and submits the
  release for App Review. A separate upload-only action stops at TestFlight, and
  Publish reuses an exact matching TestFlight build without uploading it again. See
  [One-click App Store publishing](Docs/AppStorePublishing.md).
- A guided publishing experience with per-app publish actions, release-readiness
  checks, understandable progress stages, recoverable failure details, and a
  clear completion summary. Subscription price cards, inline required-field
  errors, and a dedicated redeem-code window keep corrective work focused.
- Update-aware App Store releases that can replace an older version already in
  review after the replacement archive succeeds, while blocking duplicate
  version/build uploads.
- A default App Store Connect API plus named additional credential profiles,
  selected independently for each managed app and backed by separate Keychain
  private keys.
- Sandbox Apple Account management that lists team testers and clears a selected
  tester's complete sandbox purchase history so subscriptions and StoreKit
  introductory offers can be exercised repeatedly.
- Manual-only support, marketing, privacy-policy, privacy-choices, and Terms of
  Use URLs. Required privacy and legal links are appended to localized store
  descriptions without allowing AI-generated replacements.

## System requirements

### To run Development Management

- macOS 14.0 or newer.
- A full Xcode installation with its command-line tools selected.
- `xcrun devicectl` available from the active Xcode toolchain.
- An iPhone or iPad that is paired with Xcode, unlocked when required, and
  reported by CoreDevice as available.
- A valid Apple development team and signing setup for each managed app.
- For Wi-Fi installation, **Connect via network** enabled for the device in
  Xcode.

### To build this repository

- Xcode with Swift 5.10 support or newer.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) available as `xcodegen`.
- Standard macOS tools used by the packaging script: `hdiutil`, `codesign`,
  `ditto`, `pgrep`, `killall`, and `open`.

XcodeGen is commonly installed with:

```sh
brew install xcodegen
```

## Installation

The packaged artifact is `dist/DevManagement.dmg`.

1. Open the DMG.
2. Copy `Development Management.app` to `/Applications`.
3. Launch Development Management.
4. Find the stacked-apps icon in the menu bar.

The repository produces an unsigned, non-notarized DMG containing an app signed
with the Apple Development identity configured in `project.yml` and Xcode. On
another Mac, the first launch may require right-clicking the application and
selecting **Open**, or approving it in **System Settings → Privacy & Security**.

## Getting started

1. Open the menu-bar popover and select **Settings…**.
2. In **Applications**, select **+** and choose an iOS or macOS source folder.
3. Confirm the detected installation method, scheme, and configuration.
4. Connect and unlock an iPhone or iPad. For a network connection, first enable
   **Connect via network** in Xcode.
5. In **Applications**, select the app and choose which of its compatible
   connected iPhones and iPads should receive installations.
6. Leave **Allow installations** enabled, then select **Install now**, **Install
   All Now**, or leave automation enabled. Turn it off to pause that app.

A newly added application has no installation record, so it is immediately due
for every selected and available iOS or iPadOS device.

## Application specification

### Menu-bar popover

The menu-bar popover is the app's primary status surface. It displays:

- Current state: installing, automation paused, waiting for an iPhone, or the
  number of connected devices.
- An automation toggle.
- All paired available iPhone, iPad, and Apple Watch devices, with connection
  type.
- Installation progress and the latest command-output line while work runs.
- Determinate App Store publishing progress with **View** and cancel actions.
- Every managed application with its icon, enabled state, version, next due
  date, and most recent installation.
- A paper-plane action for publishing each eligible direct-build iOS app, plus
  a ticket action that opens a focused Redeem Codes window for apps with
  subscription products.
- A per-application Play/Pause control that resumes or pauses future
  installations directly from the menu-bar popover.
- Per-application **Install now** actions.
- **Install All Now**, **Check now**, **Publish…**, **Settings…**, and **Quit**
  actions.

When exactly one device is connected, the popover's last-install value is for
that device. Otherwise, it shows the latest installation across devices.

### Settings

Settings contains six tabs and is the only ordinary app window.

#### General

- Enable or pause automatic installation.
- Set the reinstall interval from 1 through 30 days.
- Enable or disable launch at login.
- Enable or disable success notifications.
- View the installed marketing version and build number.

#### Applications

- Add one source folder at a time.
- View each app's source path, detected version, last installation, and enabled
  or paused state.
- Enable, pause, or resume each managed application from its table row or
  detail view. Pausing prevents new automatic, manual, and Install All work;
  an installation already in progress is allowed to finish.
- Choose `install.sh` or direct Xcode installation when a script exists.
- Choose the shared scheme and build configuration for direct builds.
- View the detected platform. macOS schemes target this Mac and show their DMG
  output path; iOS schemes provide the compatible-device selector.
- View whether the selected scheme supports iPhone, iPad, or both. Only
  compatible connected devices are offered as installation targets.
- Choose installation devices independently for every app. A compatible new
  device is selected by default, and exclusions are persisted by app and UDID.
- Install the selected app immediately or reveal its folder in Finder.
- Remove one or more entries without deleting their source folders.
- Queue all enabled applications for immediate installation.
- Keep application build controls and device-selection guidance fixed and
  visible. The Settings window opens at the available screen height minus 96
  points, while only the compatible-device rows scroll when their list exceeds
  the available space.

#### Publishing

- Store the OpenAI API key and choose the model used to draft editable localized
  listing metadata, categories, content rights, free-download/sign-in answers,
  copyright, age rating, and an App Privacy checklist. Public URLs, legal
  agreements, subscription prices, review contacts, credentials, and publisher
  attestations remain manual fields.
- Store a Fastlane App Store Connect session in Keychain to publish an explicitly
  authorized **Data Not Collected** App Privacy declaration automatically.
- Configure a default App Store Connect API and any number of named additional
  profiles for apps that belong to different teams or require different keys.
- Store issuer IDs, key IDs, and profile names in app preferences while keeping
  every `.p8` private key in its own macOS Keychain account.
- Set account-wide publication defaults including locale, copyright, support
  URL, review contact, and automatic release behavior.
- Store optional App Review demo credentials only in Keychain.
- Review and cancel the latest publication from its copyable technical log.

#### Sandbox

- Choose the default or an additional App Store Connect API profile.
- Load the Sandbox Apple Accounts belonging to that developer team.
- Clear one account's sandbox in-app purchase and subscription history after a
  destructive-action confirmation. The operation is team-wide for that account,
  is irreversible, and never affects production purchases.
- Follow Apple's required device cache refresh by signing out of the Sandbox
  Apple Account and signing back in after a successful reset.
- App-managed trials based on an original download date are outside StoreKit
  purchase history and are not changed by this operation.

#### Activity

- Shows informational, success, warning, and error events newest first.
- Stores at most the latest 100 entries.
- Provides expandable, selectable build/install output and error details.
- Can be cleared manually.

#### Devices

- Lists every paired available iOS and watchOS device returned by Xcode.
- Shows name, model, operating-system family, and connection type.
- Directs device selection to each app's detail view in **Applications**.
- Treats iPhone and iPad as supported installation targets.
- Shows Apple Watch as a companion device, not an installation target.
- Supports manual refresh.

## App Store publishing

Publishing is available for managed iOS applications that use **Direct Xcode
build**. The paper-plane action on an application row opens Publish with that
application selected and locked; the footer **Publish…** action leaves the
selector available. Each app chooses the default App Store Connect API or one
named additional profile in its Publish window. Removing a named profile moves
apps that selected it back to the default API.

Before building, the readiness view compares the local source version with App
Store Connect and checks account credentials, store content, screenshots,
subscriptions, and review details. An older local checkout and an already
submitted identical version/build are blockers. When an older version is still
in active review, the action becomes **Update**: after the replacement archive
succeeds, Development Management cancels the old submission and its items,
reuses the editable version record, uploads the replacement, and starts the
review queue again. **Upload to TestFlight** runs the same complete setup as
Publish—localized store metadata, app declarations, subscriptions and territory
prices, screenshots, TestFlight information, internal group/testers, archive,
upload, processing, and build assignment—but stops immediately before App Review
submission. Review attachments are prepared and uploaded before that boundary.
A hard intent guard prevents the TestFlight path from
submitting review items. If the exact selected version and build are already in
TestFlight, either action reuses it without another archive or upload.
When another App Store version is in review, TestFlight upload continues while
Apple's locked version-scoped storefront metadata, screenshots, review assets,
and App Store build attachment are deferred until that version is released or
removed.

For a new app, the publishing editor can generate `app-store-publishing.json`
with OpenAI or accept fully manual input. All normal configuration—including
subscriptions, territory prices, age rating, and the privacy checklist—is
presented as editable fields; Advanced JSON is optional. OpenAI reads up to 2 MB
of first-party repository text—including implementation source, tests, manifests,
entitlements, dependency declarations, privacy manifests, localizations, and
documentation—and can draft localized listing text, categories, content-rights,
free-download and demo-account status, copyright, age-rating answers, and an App
Privacy checklist. Unsupported age-rating answers default to No or None; positive
answers require repository evidence. The user must review and save the draft
before Upload or Publish; neither release action silently generates or changes
it. Because Apple does not expose App Privacy through its public API,
an authorized no-data declaration is published through the Fastlane session in
Publishing Settings. Collected-data declarations retain a manual App Store
Connect confirmation path. Support and
privacy-policy URLs are required;
Terms of Use is also required for subscription apps. Marketing and
privacy-choices URLs are optional. All public URLs remain manually entered, and
the supplied Privacy Policy and Terms of Use links are appended to every
localized description within Apple's 4,000-character limit.

For subscription projects, the orange ticket action opens a dedicated Redeem
Codes window without loading the release workspace. It shows existing production
offers and creates either one-time batches of 500–25,000 codes or reusable custom
codes with 500–25,000 redemptions. Production code creation remains disabled until
App Store Connect reports a released app version and an approved subscription.
Clicking an existing offer opens One-Time and Custom tabs with active batches
first, downloadable values, redemption links, and expiration details. Apple does
not expose individual one-time redemption state through this API. New code views
warn that activation can take up to one hour and each Apple Account can redeem
only one code per offer.

For one-time batches, choose a destination before generation. Development
Management saves Apple's returned CSV directly so large batches and their
redemption URLs are ready to distribute without filling the window with codes.
Free offers are created for every territory currently enabled for the selected
subscription.

Base-territory controls use Apple's complete live territory catalog. Subscription
defaults also include a Family Sharing switch that updates every product while
retaining individual product controls. On a first release, Publish shows only the
TestFlight action until the matching build has finished processing; only then is
Submit for Review shown. Redeem Codes, live Installation Log, and Publishing Log
panels float above ordinary windows while they are open. Both live logs include
runtime, copyable command output, and automatic scrolling.

The full archive, metadata, screenshot, TestFlight, review-attachment, and
submission pipeline is documented in
[One-click App Store publishing](Docs/AppStorePublishing.md).

### Project discovery

The selected folder must directly contain at least one `.xcworkspace` or
`.xcodeproj`. Containers in nested folders are not discovered.

Discovery follows these rules:

1. Prefer the first workspace in case-insensitive filename order.
2. If there is no workspace, use the first project in filename order.
3. Run `xcodebuild -list -json` against that container.
4. Require at least one shared scheme.
5. Prefer a scheme matching the project/workspace name. Otherwise, prefer the
   first scheme whose name does not end in `Tests`, `UITests`, `Widget`,
   `Watch`, or `Share`.
6. Prefer the `Debug` configuration, then a configuration containing `debug`,
   then the first available configuration.
7. Select direct Xcode installation by default. If `install.sh` exists at the
   selected folder's root, keep it available as an optional installation method.
8. Query the selected scheme and configuration with `xcodebuild
   -showBuildSettings -json`, trying generic iOS and macOS destinations. Persist
   the detected application platform, `PRODUCT_BUNDLE_IDENTIFIER`, and whether
   the project resolves a `DEVELOPMENT_TEAM`. For iOS, read
   `TARGETED_DEVICE_FAMILY` (`1` for iPhone and `2` for iPad); if compatibility
   cannot be detected, allow both families rather than blocking installation.
9. Enable the application immediately.

Adding the same standardized folder path twice is rejected.

### Version and icon discovery

The displayed app version is refreshed whenever the menu-bar popover opens and
during device checks. Development Management looks for literal `MARKETING_VERSION`
and `CURRENT_PROJECT_VERSION` values in:

1. `.xcconfig` files up to four levels below the source folder, with filenames
   containing `version` preferred.
2. The selected `.xcodeproj/project.pbxproj`, when the selected container is a
   project.
3. An `Info.plist` up to four levels below the source folder.

Unresolved build-setting expressions such as `$(MARKETING_VERSION)` are
ignored. Missing values are displayed as **Unknown**.

For app icons, the source tree is scanned for `.appiconset` folders. Icons
matching the selected scheme are preferred, while Watch, widget, and share
extension icons are penalized. A conventionally named standalone `AppIcon`
image is used as a fallback.

## Installation methods

### Direct Xcode build

Direct installation does not require any repository-specific script. For the
selected project/workspace, scheme, configuration, and device, Development Management:

1. Regenerates a root-level XcodeGen project when `project.yml` is present.
2. Creates a temporary Derived Data directory.
3. Runs `xcodebuild` for `platform=iOS,id=<device-udid>` with a 45-second
   destination timeout.
4. Passes `-allowProvisioningUpdates` and
   `-allowProvisioningDeviceRegistration`.
5. Uses the project's resolved signing team when it has one. Otherwise,
   automatically selects a unique team whose valid Xcode provisioning profiles
   match the application's bundle-ID namespace. A team selected explicitly for
   the managed application overrides `DEVELOPMENT_TEAM` and enables Xcode
   automatic signing without modifying the source project. Available teams come
   from local Apple Development identities and valid Xcode provisioning profiles
   and can be refreshed in Settings. If no unique match exists, Settings requires
   an explicit per-application selection before the build starts.
6. Resolves the built application with `xcodebuild -showBuildSettings -json`,
   with a Derived Data scan as fallback.
7. Defines the `DEVELOPMENT_MANAGEMENT_MANAGED_INSTALL` Swift compilation
   condition so an application can recognize this local managed build without
   affecting its ordinary Xcode, archive, or App Store builds.
8. Runs `xcrun devicectl device install app --device <device-udid>
   --timeout 180 <built-app>`.
9. Removes the temporary build directory.

Paired devices reported by CoreDevice remain visible and keep their per-application
selection while their developer tunnel is connecting. Development Management actively
probes the device to establish the tunnel, but starts `xcodebuild` only after the probe
succeeds. Automatic work, per-application manual requests, and Install All remain queued
until then, with discovery retried at the regular five-minute interval instead of
starting a build against an ineligible destination. If that probe specifically times
out, Development Management restarts the user-owned CoreDevice service and retries once
per app session so a stale service does not leave every device stuck at Connecting.

The build uses the source tree's current contents and the developer account and
signing configuration available to Xcode.

For a macOS scheme, direct installation instead:

1. Builds for `generic/platform=macOS` in temporary Derived Data.
2. Stages the built `.app` with an Applications shortcut and creates a compressed
   DMG at `<project>/dist/<application>.dmg`.
3. Verifies the DMG, mounts it read-only, and stages its app in `/Applications`.
4. Gracefully stops an existing running copy, forcing it to terminate only when
   it does not exit within three seconds.
5. Replaces the installed bundle, restoring the old bundle if the final move
   fails, detaches the DMG, and launches the new copy.

Development Management refuses to use this path to replace its own running app.

Successful-installation notifications may show the installed application's
icon as an attachment. Development Management always creates a temporary copy first,
because macOS moves notification attachment files into its own data store; files
inside the managed source project are never handed to the notification system.

### Optional `install.sh`

If the selected folder contains `install.sh`, Development Management can execute it
with `/bin/bash`. The executable bit is not required.

Script contract:

- Working directory: the selected project folder.
- Environment variable: `IOS_DEVICE_UDID`, containing the target device UDID.
- For a macOS target, `MACOS_INSTALL_TARGET=local` is supplied instead.
- `DEVELOPMENT_MANAGEMENT_MANAGED_INSTALL=1` identifies both iOS and macOS
  script executions as local managed installs. A project may translate it into
  a build setting or compilation condition when it needs build-specific local
  behavior.
- Standard output and standard error are merged into the activity log and live
  progress display.
- Exit status `0` means the complete build-and-install operation succeeded.
- Any nonzero exit status means it failed and its output is recorded.
- The script is responsible for both building and installing the app.

The direct Xcode method remains available whenever an Xcode container was
successfully discovered, even if `install.sh` exists.

## Device discovery and transport support

Device discovery runs:

```sh
xcrun devicectl list devices \
  --filter "State == 'available (paired)' OR State == 'connected'" \
  --timeout 20 \
  --json-output <temporary-file>
```

The result is filtered to available paired or actively connected iOS and watchOS
devices with a nonempty UDID.
No transport allowlist is applied. Known CoreDevice values are presented as:

- `wired` or `usb` → USB
- `localNetwork` → Wi-Fi
- Any other available transport → Connected

USB arrival and removal events trigger a refresh through IOKit. Wi-Fi and all
other transports are found by CoreDevice during regular or manual discovery.

## Scheduling and retry behavior

### Automatic scheduling

- Automation is enabled by default.
- The default interval is 3 days and the configurable range is 1–30 days.
- A successful installation record is stored separately for each application
  UUID and target: a device UDID or the local Mac.
- An app/device pair with no record is due immediately.
- An app/device pair is due when the configured number of 24-hour periods has
  elapsed since its last successful installation.
- On each automatic device check, CoreDevice reports the developer apps
  installed on that device. A selected app is due immediately when its bundle
  identifier is missing or its marketing/build version is older than the
  current source version, even if its time-based reinstall date is later.
- A device version newer than the source version is not downgraded. When the
  source version cannot be determined, only the time-based schedule applies.
- If Xcode cannot temporarily resolve a managed app's bundle identifier, the
  metadata lookup stays pending and retries at the five-minute discovery
  interval instead of sleeping until the next scheduled reinstall date.
- Paused applications are excluded.
- Every due enabled application is processed only for the compatible devices
  selected for that application, one installation at a time.
- A failed app/device pair receives a five-minute in-memory cooldown before the
  next automatic attempt.

While work is due, missing, or explicitly queued, device discovery repeats at
the configured poll interval of 300 seconds. Once all known work succeeds, the
monitor sleeps until the earliest next installation date. With automation off,
or with no enabled projects, the fallback check interval is one hour; USB
connection events and **Check now** can still refresh immediately.

### Manual operations

- **Install now** ignores the schedule and targets this Mac for a macOS app; for
  iOS it targets the supplied device or every selected available device.
- **Install All Now** snapshots all currently enabled applications, ignores
  their schedules, installs macOS apps on this Mac, and installs iOS apps only
  on their selected compatible available devices. Paused applications are excluded.
- If no installation target is available, the Install All queue stays active
  in memory and checks every five minutes.
- Successful items leave the queue. Failed items remain queued for another
  attempt.
- Only one installation can run at a time.
- **Check now** refreshes versions and devices and may install automatically due
  work when automation is enabled.

## Notifications

Notification permission is requested on startup when notifications are enabled
and again when the setting is turned back on. Each successful application
installation produces its own banner and sound, even while Development Management is
frontmost. The notification includes:

- Application name.
- Device name and model.
- USB, Wi-Fi, or generic connection description.
- The discovered application icon when one is available.

Failures are written to Activity and are not sent as notifications.

## Persistence

State is encoded as pretty-printed JSON with ISO-8601 dates at:

```text
~/Library/Application Support/DevManagement/state.json
```

Persisted data includes:

- Installation and publishing preferences, including named App Store Connect
  profile names and identifiers.
- Managed-project paths, build choices, supported device families, paused
  state, per-project device-UDID exclusions, and the selected App Store Connect
  credential profile.
- Per-project, per-device successful installation records and installed
  versions.
- The latest 100 activity entries and their command output.
- Whether the first-run launch-at-login default has been applied.

OpenAI and App Store Connect API keys and App Review demo credentials are stored
separately in macOS Keychain and are never written to `state.json` or an app's
`app-store-publishing.json`.

The pending Install All queue, discovered device list, icon cache, and failed
attempt cooldowns are runtime-only and are rebuilt or discarded after relaunch.

## Localization

The app ships complete English (`en`) and Hebrew (`he`) string tables and uses
the locale selected for Development Management in macOS. Dates, times, numeric values,
and formatted messages use the current system locale.

New user-visible text must be added to both:

- `Resources/en.lproj/Localizable.strings`
- `Resources/he.lproj/Localizable.strings`

## Privacy and security

- Development Management operates locally and does not provide its own cloud service
  or analytics pipeline.
- Device discovery and installation are delegated to the active Xcode
  toolchain.
- The app is intentionally not sandboxed so it can access user-selected source
  trees, execute their scripts and build tools, and work with Xcode/CoreDevice.
- Hardened Runtime is enabled.
- Launch at login is managed with `SMAppService.mainApp`.
- Project scripts run with the current user's privileges. Add only trusted
  source folders and review their `install.sh` before using it.
- Build and installation output may contain local paths or tool diagnostics and
  is stored in the local Activity history.
- Publishing metadata generation sends the managed app's name, version,
  identifiers, and up to 2 MB of readable first-party repository text to the
  configured OpenAI model. Generated builds, vendor dependency source, binaries,
  symlinks, and known credential files are excluded. Because first-party source
  is uploaded for analysis, secrets must not be hard-coded in tracked source.
- Keychain status checks read item attributes without requesting secret data.
  Private keys are read only when needed and cached in memory for the rest of
  the app session.
- The packaged app uses the Apple Development signing identity configured in
  Xcode. The DMG itself is unsigned and is not notarized.

## Architecture

```text
DevManagementApp
├── MenuBarExtra
│   └── MenuBarView
├── Settings
│   ├── GeneralSettingsView
│   ├── ProjectsSettingsView
│   ├── PublishingSettingsView
│   ├── ActivityView
│   └── DevicesSettingsView
├── PublishingWindow / RedeemCodesWindow
└── AppModel
    ├── SettingsStore
    ├── ProjectDiscoveryService
    ├── ProjectVersionService
    ├── ProjectIconService
    ├── DeviceService
    ├── USBConnectionMonitor
    ├── InstallationService
    │   └── ProcessRunner
    ├── AppStorePublishingService
    ├── AppStoreConnectService
    ├── OpenAIStoreMetadataService
    ├── KeychainCredentialStore
    ├── NotificationService
    └── LaunchAtLoginService
```

`AppModel` is isolated to the main actor and owns UI state, monitoring,
scheduling, queues, installation serialization, and persistence. Services own
filesystem discovery, subprocess execution, CoreDevice parsing, notifications,
and system integrations.

Key project settings:

| Setting | Value |
| --- | --- |
| Product | Native SwiftUI macOS application |
| Minimum macOS | 14.0 |
| Swift language version | 5.10 |
| Display name | `Development Management` |
| Bundle identifier | `com.zivtal.DevManagement` |
| App category | Developer Tools |
| Activation policy | Accessory |
| `LSUIElement` | `true` |
| App Sandbox | Disabled |
| Hardened Runtime | Enabled |
| Frameworks | IOKit, Security, UserNotifications |

## Repository layout

```text
.
├── project.yml                 # Source of truth for the Xcode project
├── DevManagement.xcodeproj/    # Generated by XcodeGen
├── Sources/
│   ├── App/                    # App entry point, model, localization helper
│   ├── Models/                 # Projects, devices, state, scheduling
│   ├── Services/               # Xcode/CoreDevice and macOS integrations
│   └── Views/                  # Menu bar and Settings UI
├── Resources/
│   ├── Assets.xcassets/        # Application icon assets
│   ├── en.lproj/               # English localization
│   └── he.lproj/               # Hebrew localization
├── Tests/                      # XCTest unit tests
├── Tools/                      # Development-time asset tools
├── scripts/
│   ├── bump-version.sh         # Marketing/build version bump
│   └── build-dmg-unsigned.sh   # Release, DMG, install, and launch workflow
└── dist/                       # Packaged DMG output
```

The `.xcodeproj` is generated output. Make project-structure and build-setting
changes in `project.yml`, then regenerate it.

## Development

Generate the Xcode project:

```sh
xcodegen generate
```

Open it in Xcode:

```sh
open DevManagement.xcodeproj
```

Or build from the command line:

```sh
xcodebuild \
  -project DevManagement.xcodeproj \
  -scheme DevManagement \
  -destination 'platform=macOS' \
  build
```

Because Development Management is an accessory app, launching it does not create a
Dock icon or ordinary main window. Use its menu-bar icon to open the popover and
Settings.

## Tests

Run the unit-test suite with:

```sh
xcodebuild test \
  -project DevManagement.xcodeproj \
  -scheme DevManagement \
  -destination 'platform=macOS'
```

Current unit coverage verifies:

- CoreDevice JSON decoding, paired-device filtering, transport independence,
  device ordering, and Watch exclusion from installation targets.
- Default, excluded, restored, and legacy-decoded device installation choices.
- Reinstall threshold behavior and the one-day scheduling minimum.
- Success-notification content.
- iPhone app-icon preference over Watch icons.
- Version lookup precedence for version `.xcconfig` files.
- Publishing readiness, friendly five-stage progress, version/update selection,
  exact TestFlight build matching, active-review detection, and duplicate/draft
  handling.
- App Store metadata generation limits, manual URL policy, localized privacy and
  Terms link insertion, screenshots, StoreKit discovery, and offer-code payloads.
- Offer-code production eligibility, CSV parsing, and subscription-price
  validation.
- Named App Store Connect profile persistence, separate Keychain accounts,
  attribute-only existence checks, per-app selection, and legacy decoding.

Manual release validation should also cover USB and Wi-Fi discovery, direct and
script-based installation, Settings persistence, launch at login, notifications,
and the absence of a Dock icon.

## Versioning, packaging, and local deployment

Every completed change or fix must follow this sequence exactly:

1. Bump the version once.
2. Run the unit tests.
3. Run the DMG build/deployment script once.

```sh
scripts/bump-version.sh

xcodebuild test \
  -project DevManagement.xcodeproj \
  -scheme DevManagement \
  -destination 'platform=macOS'

scripts/build-dmg-unsigned.sh
```

`scripts/bump-version.sh` increments the marketing patch version and build
number in `project.yml`. Patch and minor components roll over after 9.

`scripts/build-dmg-unsigned.sh` is the complete deployment step. It:

1. Regenerates the Xcode project with XcodeGen.
2. Performs a clean Release build with the configured automatic Apple
   Development signing identity.
3. Creates `dist/DevManagement.dmg` with an `/Applications` shortcut.
4. Verifies the DMG.
5. Stops a running `Development Management` process.
6. Replaces `/Applications/Development Management.app` atomically through a temporary
   application copy.
7. Verifies the installed app's signature.
8. Launches the installed copy.
9. Reports the installed marketing version, build number, and DMG size.

Do not manually repeat the process termination, `/Applications` replacement, or
launch around this script.

## Troubleshooting

### No device appears

- Open Xcode and confirm the device is paired and available.
- Unlock the device and accept trust or Developer Mode prompts.
- Confirm `xcrun devicectl list devices` reports it as `available (paired)` or
  `connected`.
- For Wi-Fi, enable **Connect via network** for the device in Xcode.
- Select **Check now** or **Settings → Devices → Refresh devices**.

### The project cannot be added

- Confirm a `.xcworkspace` or `.xcodeproj` is directly inside the selected
  folder.
- Confirm the app's scheme is marked **Shared** in Xcode.
- Run `xcodebuild -list -json` against the selected container to inspect Xcode's
  response.
- If multiple containers exist, remember that Development Management prefers the first
  workspace, then the first project.

### A direct build fails

- Open the same scheme in Xcode and build it for the same physical device.
- Resolve signing, provisioning, capability, or package-resolution errors in the
  source project.
- Check the expandable Activity details for the complete merged `xcodebuild`
  and `devicectl` output.
- Confirm the selected scheme produces an installable iOS `.app`, not only a
  test, extension, or Watch product.

### `install.sh` fails

- Run the script with `/bin/bash` from the project folder.
- Confirm it reads `IOS_DEVICE_UDID` and performs both build and installation.
- Return exit status `0` only after installation has succeeded.
- Switch the project to **Direct Xcode build** if the script is stale or no
  longer needed.

### No notification appears

- Enable notifications in **Settings → General**.
- Allow Development Management in **System Settings → Notifications**.
- Confirm the Activity log records a successful installation.

## Current constraints

- Development Management manages local source folders; it does not clone, pull, or
  otherwise update source control.
- Its schedule is elapsed time since a successful installation, not the
  provisioning profile's measured expiration.
- Project/workspace discovery is limited to the selected folder's top level.
- Only shared schemes returned by `xcodebuild -list -json` are usable.
- Direct installation targets iOS-platform devices; discovered Apple Watch
  devices are informational.
- One build/install operation runs at a time.
- Install All targets the selected installable devices available when its queue
  starts; the pending queue is not restored after relaunch.
- Failed-attempt cooldowns are not persisted across relaunches.
- The Activity log retains only the latest 100 entries.
- The DMG is unsigned and not notarized for public distribution; its app keeps
  the configured Apple Development signature.
