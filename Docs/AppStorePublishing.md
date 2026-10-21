# One-click App Store publishing

Development Management inspects each managed iOS or native Mac project when **Publish** is
clicked. A local Xcode StoreKit configuration (`*.storekit`) is the preferred
source for subscription groups, products, periods, prices, and localizations.

For a first publication, **Create App…** opens Apple's sign-in page inside the
app. Enter the app name, SKU, locale, and platforms after selecting the correct
Apple team. Creation uses Apple's authenticated website endpoint because the
[public API does not create app records](https://developer.apple.com/documentation/appstoreconnectapi/apps).
Website endpoints are not a stable public contract: if creation is rejected,
complete it with Apple's controls in the same window, then refresh. **Apple
Account…** also provides account agreements and privacy setup. WebKit keeps the
session locally; the app never extracts Apple passwords or cookies.

Configure both schemes in the schema-2 `platforms` section, then select iOS, macOS,
or both in the Publish window. Publish completes each selected platform through
build processing and confirmed App Review submission. They may share one App Store
record when their store bundle identifiers match. Watch and widgets are embedded in
the iOS upload. The Mac scheme must be sandboxed and specify an app category.
Mac export obtains its own installer certificate, creates a signed `.pkg`, and
keeps Mac builds, review submissions, profiles, and screenshots separate from
iOS. Mac screenshot capture uses only the selected app's window and Apple's
[accepted screenshot dimensions](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

The dedicated signing keychain is unlocked with its stored generated password.
Status checks suppress authentication UI, and existing imported keys have their
Apple signing-tool access repaired. Missing or inaccessible stored credentials
stop publishing with an error; no keys are deleted or passwords guessed.

If the generated password is missing or rejected, choose **Settings → Publishing
→ Repair Signing Keychain**. After confirmation, the app preserves and verifies a
backup before replacing an unusable keychain. A working keychain is kept. The
backup remains locked with its original password, and its location is shown even
if replacement fails. Repair never revokes Apple certificates or starts an upload.
Retry publishing afterward; preparing a new signing identity may require an
available certificate slot. Repair is unavailable while managed work is active.

The optional `app-store-publishing.json` file belongs in the managed app's root
folder. It supplies production settings that aren't represented by StoreKit.
For a free app, publishing verifies an active zero-price entry rather than merely
checking that a price schedule exists. An empty or non-free base price is replaced
with the configured Free price.

In **Publishing Configuration → Review → Submission**, set **Uses non-exempt
encryption** only after confirming the app's export-compliance answer. The default
preserves the uploaded build's declaration, including one supplied by its
`ITSAppUsesNonExemptEncryption` Info.plist key. An unspecified answer is never
assumed to be false. An explicit choice updates the existing build through App
Store Connect without rebuilding or changing its version. Non-exempt encryption
may also require documentation in App Store Connect.

Watch screenshots require an installed watchOS Simulator runtime and an available
Watch simulator, or a supplied screenshot. Missing simulator families are reported
in the publishing log; cached screenshots are reused on the next attempt.

Saved manifest values are authoritative. For a new app, the publishing editor
can ask OpenAI to prepare a conservative, evidence-backed draft from bounded
`README.md` and project-manifest excerpts. Every generated value is placed in a
normal editable field and must be reviewed and saved before either release
action can start. Upload and Publish never generate or change saved metadata.
The dedicated What’s New button looks up the earlier Apple-approved version and
resolves its ancestor release tag or exact marketing-version declaration in Git.
The evidence covers the full commit interval, net changed files, and bounded
source diffs through the current tracked working tree. README release notes are
supplementary. Major new capabilities take priority over their later fixes.
A missing Git baseline produces an actionable error instead of silently using
recent commits. Excerpts have separate size budgets and disclose omissions.
The draft must be reviewed and saved before submission.

```json
{
  "schemaVersion": 1,
  "publication": {
    "locale": "en-US",
    "copyright": "2026 Company Name",
    "supportURL": "https://example.com/support",
    "releaseAutomatically": false,
    "screenshotPaths": ["Screenshots", "Marketing/iPhone-6.7.png"],
    "reviewAttachmentPaths": ["AppStore/ReviewAttachments"],
    "review": {
      "contactFirstName": "Review",
      "contactLastName": "Contact",
      "contactPhone": "+1 555 0100",
      "contactEmail": "review@example.com",
      "notes": "Open the Premium tab to find the paywall.",
      "demoAccountRequired": false
    },
    "testFlight": {
      "groupName": "Internal Testing",
      "feedbackEmail": "review@example.com",
      "reviewNotes": "No account is required.",
      "internalTesterEmails": ["review@example.com"]
    }
  },
  "application": {
    "primaryCategory": "FINANCE",
    "secondaryCategory": "UTILITIES",
    "contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT",
    "isFree": true,
    "baseTerritory": "USA",
    "availableInAllTerritories": true,
    "ageRating": {
      "advertising": false,
      "gambling": false,
      "gamblingSimulated": "NONE",
      "medicalOrTreatmentInformation": "NONE",
      "unrestrictedWebAccess": false,
      "userGeneratedContent": false
    }
  },
  "compliance": {
    "privacyDraft": {
      "collectsData": false,
      "dataTypes": [],
      "notes": ["Confirm the shipped SDK behavior in App Store Connect."]
    },
    "privacyAttestation": {
      "confirmedBy": "Publisher Name",
      "confirmedAt": "2026-08-17T10:00:00Z",
      "automaticPublishingAuthorizedAt": "2026-08-17T10:00:00Z"
    }
  },
  "subscriptions": {
    "baseTerritory": "ISR",
    "availableInAllTerritories": true,
    "familySharable": true,
    "reviewScreenshot": "Screenshots/subscription-review.png"
  }
}
```

Open **Publish… → Per-App Configuration…** to create, edit, validate, and save
this file without leaving Development Management. The standard tabs provide
fields for the listing, app answers, age rating, privacy checklist, review,
TestFlight, subscription groups/products/localizations, and territory prices.
**Advanced JSON** is optional and edits the same configuration. Account-wide
defaults live in Publishing Settings; values in this file override them for this
app. API keys, private keys, and demo-account passwords are never written to the
file.

Publishing Settings supports multiple named App Store Connect API profiles. Each
managed app selects either the default API or one additional profile in its
Publish window. Issuer and key identifiers are stored in app preferences, while
each profile's private key is kept under a distinct macOS Keychain account.
Removing a profile returns apps that selected it to the default API.

The same credential profiles power the Sandbox settings tab. Development
Management uses Apple's sandbox-tester API to list accounts for the selected
team and, after explicit confirmation, clear one account's complete sandbox
in-app purchase and subscription history. This restores StoreKit introductory
offer eligibility but does not alter production purchases or app-managed trial
state derived from an original download date. Testers must sign out of their
Sandbox Apple Account on the device and sign in again after the reset so the
device discards its cached transaction history.

Keychain status checks inspect item attributes without decrypting the stored
secret, so opening the app or Settings does not ask for credential access. The
secret is read only when its publishing operation needs it and is cached in
memory for the rest of that app session to avoid repeated prompts. macOS controls
all Keychain authorization prompts; the app cannot select **Always Allow** for
the user. Ad-hoc signed development builds can require authorization again after
an update because their code identity changes. The repository's DMG deployment
therefore preserves Xcode's configured Apple Development signing identity for
the installed app instead of forcing an ad-hoc signature.

To use hand-written App Store text instead of OpenAI, add all four metadata
fields under `publication` (the editor's **Insert Manual Metadata Fields** button
does this):

```json
"metadata": {
  "description": "A factual customer-facing description.",
  "keywords": "keyword,another",
  "promotionalText": "Optional promotional text.",
  "whatsNew": "What changed in this version."
}
```

Use **Generate Settings with OpenAI** before a new app's first release to create
localized listing fields and safe answer drafts. OpenAI receives bounded excerpts
from `README.md`, relevant
root/legal submission and privacy guides (including files such as
`TripFlowSubmissionAndAutomation.md`), `project.yml`, package-resolution files,
privacy manifests, and common app manifests. It treats this project text as
untrusted evidence and returns structured fields only. Descriptions cover
verified features, audience, value, privacy-relevant behavior, and named
third-party providers found in that evidence.

The same pass drafts the primary/secondary category, third-party content
rights, whether the app is free to download, whether a demo account is needed,
the copyright holder, age-rating answers, and an App Privacy checklist. Each
explicit generation refreshes the age-rating and App Privacy drafts while saved
listing and manually entered values remain in place. Generation never runs
inside a release action. The publisher can edit all fields before saving. OpenAI
never invents public URLs, prices,
credentials, provider capabilities, legal agreements, release behavior, or
offer-code terms. Copyright input such as `Company Name` is normalized to
`<current year> Company Name`; an existing leading year is preserved.

Generation also fills an unset **Uses non-exempt encryption** answer when the
repository supports a Yes or No recommendation. It examines network transports,
authentication, credential storage, dependencies, entitlements, and encryption
implementations, distinguishing router-side VPN controls from an in-app tunnel.
The generated answer needs an affirmative evidence-sufficiency flag and nonempty
source evidence; uncertain answers stay unset. Existing Yes/No selections are
preserved. Supporting excerpts are saved with the declaration and appear under
**AI encryption evidence** in **Review → Submission**, where the answer remains
editable before saving. Generating
only age ratings, App Privacy, or What’s New does not change this selection.

The Store Description section has a dedicated **Generate What’s New with
OpenAI** button. It looks up the latest earlier Apple-approved version, uses its
matching ancestor release tag or exact version declaration as the Git baseline,
and drafts a short localized customer-facing summary across the full interval.
Only the primary and existing localized What’s New fields are replaced.

Optional map, AI, imported-document, flight, hotel, or other provider content is
treated as third-party content when the project documentation says the app may
show or access it. That produces `USES_THIRD_PARTY_CONTENT` even when the feature
is user-controlled or optional.

Support, marketing, privacy-policy, privacy-choices, and Terms of Use URLs are
manual fields. Support and privacy-policy URLs are required, and Terms of Use is
also required for apps with subscriptions. Marketing and privacy-choices URLs
remain optional. Publish appends the manually supplied Privacy Policy and Terms
of Use links to every localized description while preserving Apple's 4,000
character limit; OpenAI does not create or replace those links.

Apple does not expose the App Privacy questionnaire through the public App Store
Connect API. For an explicitly reviewed declaration, whether **Data Not
Collected** or collected data types with their purposes, linking, and tracking
answers, Development Management publishes the answers through the built-in
Apple web session; the following Fastlane configuration is an optional legacy
alternative. Collected data is editable per Apple category in App Setup, and a
category without a purpose keeps the declaration on the manual path. Publishing
sends one record per category, purpose, and protection, the same shape as
Fastlane's `upload_app_privacy_details_to_app_store`; answers already present in
App Store Connect are kept when they match, replaced when a reviewed
collected-data draft differs, and never replaced by a no-data declaration.
It uses Fastlane's authenticated
App Store Connect web session. Publishing Settings stores the Apple ID in app
preferences and the `FASTLANE_SESSION` value in Keychain; the Apple ID password
is never stored. Run the copied `fastlane spaceauth` command, paste the returned
session, and authorize the per-app declaration in App Setup. A successful run
records `publishedAt` in the manifest and does not repeat the operation unless
the privacy draft changes. When Apple rejects the saved Fastlane session, the
run stops with a single instruction to sign in with Apple Account in the
publishing window or refresh the session with `fastlane spaceauth`, instead of
Fastlane's login fallback output. A collected-data draft that still lacks a
purpose can instead be published by hand in App Store Connect, followed by the
manual confirmation in the editor.

If an app doesn't use a local StoreKit configuration, the manifest can contain
the complete subscription catalog:

```json
{
  "schemaVersion": 1,
  "subscriptions": {
    "baseTerritory": "ISR",
    "availableInAllTerritories": true,
    "reviewScreenshot": "Screenshots/subscription-review.png",
    "groups": [{
      "referenceName": "Premium",
      "localizations": [{
        "locale": "en-US",
        "name": "Premium"
      }],
      "subscriptions": [{
        "referenceName": "Premium Monthly",
        "productID": "com.example.app.premium.monthly",
        "period": "ONE_MONTH",
        "basePrice": "9.90",
        "territoryPrices": {
          "ISR": "39.00",
          "USA": "13.90"
        },
        "familySharable": true,
        "groupLevel": 1,
        "reviewNote": "Monthly access to all premium features.",
        "localizations": [{
          "locale": "en-US",
          "name": "Premium Monthly",
          "description": "All premium features for one month."
        }]
      }]
    }]
  }
}
```

Supported periods are `ONE_WEEK`, `ONE_MONTH`, `TWO_MONTHS`, `THREE_MONTHS`,
`SIX_MONTHS`, and `ONE_YEAR`; ISO StoreKit periods such as `P1M` and `P1Y` are
also accepted. Prices are matched to Apple's price points in `baseTerritory`.
If an exact point does not exist, Publish selects the numerically nearest
available point, chooses the lower point on an exact tie, and reports the
requested and selected prices before changing the schedule.
When all-territory availability is enabled, the publisher applies Apple's
equalized price point in every available territory.
Explicit `territoryPrices` override Apple's equalized point for those ISO 3166-1
alpha-3 territories. Existing matching schedules are reused; a changed active
territory price is scheduled from the next day because Apple price schedules are
append-only.

Every run reconciles app information, availability, a free app price when
explicitly requested, subscription groups and products, current v2 versioned
localizations, paywall review screenshots, territory prices, App Store
screenshots, TestFlight information, and internal testing access. Existing
matching resources are reused. A published version remains immutable, while a
new editable version receives the current localized version metadata. Listing,
subscription-group, and subscription-product locales are normalized to App Store
Connect's supported identifiers, including `he-IL` to `he`, before reconciliation.
The locale is sent when a localization is created and omitted from later updates
because App Store Connect treats that attribute as immutable. Locales imported
from App Store Connect are canonicalized before the generated per-app JSON is
saved, so regional aliases do not persist through a configuration round trip.

## Resuming a release

Run the same release action again after a failure or cancellation. Successful
archive, export, validation, and upload checkpoints survive app restarts. Failed
steps are retried; a partial archive or export is never treated as completed.

- If export fails, reuse the completed local archive and retry export.
- If validation or upload fails, reuse the saved IPA. A previously successful
  validation is skipped only for the same SHA-256-verified IPA.
- If Apple already has the exact iOS marketing version and build, skip archive,
  export, validation, and upload. Build Uploads are checked as well as TestFlight,
  so an accepted build still processing is not uploaded a second time.
- After a processing timeout, retry the processing check. Apple's upload errors
  are reported when available rather than hidden behind a generic timeout.
- Matching listing fields, TestFlight information, app declarations, build
  attachments, and complete matching replacement screenshots are not rewritten.
  Existing products, prices, groups, and review assets continue to be reconciled
  against Apple, so edited configuration is applied and missing work is completed.
- Publish detects when the exact build is already in review or released and
  finishes without restarting that release.

Artifacts are stored privately under
`~/Library/Application Support/DevManagement/PublishingArtifacts`. Each checkpoint
is isolated by project path, container, scheme, configuration, signing team,
App Store Connect issuer/application, bundle identifier, marketing version, and
build number. API keys remain temporary and are never saved in this directory.
Successful publication removes the large local artifacts and retains the upload
receipt. Unfinished releases keep their artifacts for retry.

The saved binary is a snapshot of that version/build, just like an uploaded
TestFlight build. Retrying the same version/build intentionally uses that snapshot,
even if source files subsequently changed. A new repository version/build starts
fresh; publishing never increments either value. Metadata edits do not require
rebuilding the binary and are reconciled on retry.

## Shared release pipeline

**Upload to TestFlight** and **Publish** run the same setup pipeline in this
order:

1. Discover StoreKit products and deterministic per-app configuration.
2. Publish the authorized App Privacy declaration, no-data or collected data,
   when it has not already been published.
3. Validate every configured public support, marketing, privacy, and terms URL
   before spending time on an archive that cannot be submitted.
4. Prepare or capture App Store screenshots for each supported simulator family.
   Capture builds use the selected simulator destination and a scheme with repository
   pre/post actions removed. Xcode resolves package products and each dependency's
   SDK, including the watchOS SDK for an embedded Watch app. Companion Watch apps
   are detected from source Info.plists and generated-plist Xcode build settings,
   so they receive their own simulator screenshot even without a source plist.
5. Look for the exact selected marketing version and build in TestFlight. When
   it is already present, reuse it and skip the archive and upload. Otherwise,
   resume a saved archive/export when available, or archive the selected iOS scheme with repository
   pre/post action scripts removed. The selected App Store Connect `.p8` key is
   passed to Xcode for automatic signing and provisioning, so export does not
   depend on an Apple Account session stored in Xcode.
6. When an archive is required, read its bundle identifier, marketing version,
   and build number. They must exactly match the selected source version and
   build; publication stops without uploading if either changed. The archived
   iOS app's interface orientations are checked next, before any App Store
   metadata is written: a bundle with no `UISupportedInterfaceOrientations`, or
   an iPad-capable bundle missing one of the four orientations without
   `UIRequiresFullScreen`, stops publication with the Info.plist key to fix
   instead of waiting for Apple's ITMS-90474 rejection during upload. A reused
   TestFlight build is confirmed as fully processed before the App Store version
   is changed.
7. Create or update the App Store version and reconcile localized listing text,
   app categories and declarations, availability, app pricing, subscription
   groups/products/localizations/prices, and localized screenshots. When an
   archive was required, validate and upload its IPA. The upload returns as soon
   as Apple accepts the transfer because processing is monitored separately. A
   poisoned transfer that repeatedly reports checksum mismatches is stopped and
   restarted, with at most three upload attempts.
8. Wait for Apple to process the exact archived build and attach it to the exact
   archived marketing version.
9. Reconcile localized TestFlight descriptions, URLs, beta review information,
   the configured internal group, and internal tester email addresses. Internal
   testers must already be App Store Connect team members; the run fails clearly
   rather than attempting to grant account access.
10. Upload configured App Review demo videos and documents and verify Apple has
   processed each asset.

At that boundary **Upload to TestFlight** stops. A hard intent guard prevents
that action from creating, canceling, or submitting an App Review submission.
It is idempotent: existing builds, metadata, products, prices, screenshots,
groups, and tester assignments are reused when they already match.

When another App Store version is already in review, Apple does not allow the
TestFlight build's new App Store version record to be created. The TestFlight
action continues by uploading and processing the build and reconciling beta
information, groups, testers, and subscriptions. Version-scoped storefront
metadata, screenshots, review details and attachments, and App Store build
attachment are deferred until the reviewed version is released or removed.

App Store Connect may return both the locked live App Info record and the
editable record for the next version. Metadata reconciliation always targets
the editable record, preferring `PREPARE_FOR_SUBMISSION`, so localized app name,
subtitle, privacy URLs, categories, and age rating are applied to the upcoming
release rather than rejected against the live record.

Existing localized App Info is patched only when a configured value changed.
If Apple rejects only a requested rename because the name is unavailable, the
existing localized name is preserved and reported in the publishing log while
the remaining subtitle and privacy values continue to reconcile. Creating a
new localization and unrelated conflicts still fail without fallback.

**Publish** additionally cancels an explicitly confirmed older active review
only after the replacement archive succeeds (or a matching processed build is
already available), then continues with the
review-only tail:

10. Create one submission containing the App Store version, subscription group
    versions, and subscription versions, then send the complete submission to
    App Review.

When the managed folder contains a root `project.yml` and the selected container
is a root-level Xcode project, Development Management regenerates the project
with XcodeGen immediately before a direct build or archive. Newly added source
files are therefore included, while scheme pre/post actions remain disabled and
the app's existing version is preserved. If a command still fails, the alert shows the relevant compiler or
archive diagnostics while Activity retains the complete command output.

The menu-bar application list includes a paper-plane action for every eligible
iOS app and a ticket action for projects that contain subscription products.
The ticket opens a focused Redeem Codes window for that app without loading the
release workspace. The paper-plane action opens Publish with that app selected
and locks the application selector; the footer Publish button keeps the selector
available when the app should be chosen inside the release window. A
release-readiness panel checks the selected source version against App
Store Connect, validates account setup, and summarizes store content,
screenshots, subscriptions, and review details. An older local checkout is
treated as a blocker instead of silently building a version behind the live App
Store record.

Opening Publish gives immediate feedback in the menu and presents a lightweight
loading window before project, App Store Connect, subscription, and screenshot
checks begin. Existing App Store Connect support, copyright, and review-contact
values are reused when a per-app or account default does not override them.
The action remains clickable when editable data is incomplete: Publish opens the
relevant configuration tab and marks each missing required field with a red
border and an inline explanation.

The right-hand workspace switches between **Subscriptions** and **Redeem Codes**.
Subscription cards expose each product's duration, base territory, availability,
Family Sharing, and requested base price. Every base-territory field is a picker
backed by the complete live App Store Connect territory catalog. The subscription
default Family Sharing switch updates every product, while product-level switches
remain editable. Saved price edits update `app-store-publishing.json`
and are applied to App Store Connect by the next Publish run. Redeem Codes shows
existing production offers and creates either Apple one-time code batches or a
custom reusable code, using the selected subscription. Switching tabs preserves
the release window layout; code creation has its own in-tab action, while the
footer **Upload to TestFlight** and **Publish** or **Update** actions belong to
the release workflow. Publish always submits for App Review; the TestFlight
action is the explicit upload-only path. The window also remains open when
another application or Development Management window receives focus.

The footer always offers **Publish** as the primary action, including the first
release before any build exists in TestFlight. It uploads, waits for processing,
attaches the build, and submits for review in one run. An already processed
matching build changes the label to **Submit for Review** and is reused without
another archive or upload. Existing released apps show the normal update action.
**Upload to TestFlight** remains a separate action for intentionally stopping
before App Review.

When App Store Connect reports an older app version in an active review state,
the release action is labeled **Update** and identifies that version. The final
confirmation explains that the active submission and all of its items will be
canceled, the editable version will be replaced, and the review queue will start
again. If no app version is in review, Update uploads and submits normally. The
same local version and build already submitted to Apple remain blocked to avoid
a duplicate submission. A matching build that is only in TestFlight is not
blocked: Publish attaches it to the App Store version and submits it without
another archive or upload.

After confirmation, Publish closes and a dedicated always-on-top Publishing Log
opens with five understandable stages: Prepare, Build, App Store setup,
TestFlight, and Review. The current task, overall completion, runtime, friendly
explanation, and automatically scrolling command output remain visible. The same
determinate progress appears in the menu bar, where **View** reopens the log. A
failed run keeps its exact failure step and offers a direct return to the
readiness screen; a successful run shows the archived version, build, and
destination.

Review attachments can be entered in **Per-App Configuration → App Review** or
placed under `AppStore/ReviewAttachments` in the managed project. Supported
project files are MP4, MOV, PDF, DOC, DOCX, RTF, TXT, and ZIP. Relative paths are
resolved from the managed project root; absolute paths and `~` are also accepted.
Existing complete attachments with the same filename and size are preserved.

After Publish succeeds, Development Management rereads the managed project's
version files so a scheme-driven version increment appears immediately in the
application list. The list intentionally reports the selected local source
checkout, not a remote branch or a build produced from another Git worktree.

## Subscription offer codes

Choose **Offer Codes** in the Publish window after a subscription has been
detected. Development Management can create or exactly reuse an immutable free
offer and then create either:

- a production one-time-use batch of 500–25,000 unique codes, with a required
  expiration date no more than six months away; or
- a named custom code containing 1–64 letters or digits, with 500–25,000
  redemptions per batch and an optional expiration date.

Offer duration, new/existing/expired subscriber eligibility, introductory-offer
interaction, renewal behavior, product, code quantity, and expiry are chosen in
the app. Custom-code generation replaces the setup form with the reusable code
and Apple's redemption URL. The app warns before and after creation that Apple
can take up to one hour to make a new production code redeemable and that each
Apple Account can redeem only one code per offer. One-time batches prompt for a
destination before the production request and save Apple's returned CSV directly
to disk. Code creation
is unavailable until App Store Connect reports at least one app version ready
for distribution and reports the selected
subscription as approved; the same checks are repeated by the service immediately
before a production request. New free offers include a price relationship for
every territory currently enabled for the subscription, as required by App Store
Connect. The inline territory-price resources use App Store Connect local IDs
in the `${local-id}` form, and the offer's price relationships reference those
same IDs.

Existing offers are clickable. Their detail view has **One-Time Codes** and
**Custom Codes** tabs, orders active batches before inactive or expired batches,
downloads one-time values, and provides copy actions and redemption links.
Apple's subscription offer-code API does not expose which individual one-time
values have already been redeemed or a custom batch's remaining redemption
count, so the app labels that limitation instead of guessing a per-code state.

Apple still requires the initial App Store Connect app record, signed legal
agreements, banking and tax information for paid content, collected-data App
Privacy answers, DSA trader status, any compliance declarations that aren't
exposed through the API, and at least one eligible App Store Connect user for
internal testing.
Apple also requires the first subscription submission to be completed together
with an app binary on the App Store Connect website; after that first submission,
Development Management submits versioned subscription and group resources by
API. Subscriptions inherit the parent app's App Store software tax category by
default unless the publisher explicitly changes it in App Store Connect.
Publish does not fabricate legal answers, accept agreements, grant team roles,
reply to App Review messages, or create missing public support and privacy
websites.

## Platform selection, changed releases, and diagnostics

Publishing schema version 2 declares each platform explicitly. The Publish window
shows platform checkboxes and defaults to `defaultPlatforms` (or all configured
platforms when omitted). Selecting only macOS never archives, uploads, attaches,
or submits an iOS version. A failed selected platform stops the run and reports
completed platforms; it cannot produce an overall success. Release work is
sequential, and Apple may retain an earlier successful platform if a later one fails.

```json
{
  "schemaVersion": 2,
  "defaultPlatforms": ["MAC_OS"],
  "publication": {
    "locale": "en-US",
    "copyright": "2026 Example",
    "supportURL": "https://example.com/support",
    "privacyPolicyURL": "https://example.com/privacy",
    "metadata": {
      "description": "Shared app description",
      "keywords": "router,wifi",
      "promotionalText": "",
      "whatsNew": "Reviewed release notes"
    },
    "review": {
      "contactFirstName": "Pat",
      "contactLastName": "Lee",
      "contactEmail": "review@example.com",
      "contactPhone": "+1 555 0100",
      "demoAccountRequired": false,
      "notes": "Hardware setup and review instructions.",
      "demoVideoRequired": true,
      "demoVideoURL": "https://example.com/hardware-demo"
    }
  },
  "platforms": {
    "IOS": {
      "scheme": "ExampleIOS",
      "sourcePaths": ["Apps/iOS", "Apps/Shared", "Sources", "project.yml"]
    },
    "MAC_OS": {
      "scheme": "ExampleMacStore",
      "configuration": "Release",
      "sourcePaths": ["Apps/Mac", "Apps/Shared", "Sources", "Config/Mac-Info.plist", "Config/MacStore.entitlements", "project.yml"],
      "archiveRequirements": {
        "networkClient": true,
        "keychainAccessGroups": ["TEAMID.app.example.credentials"],
        "encryptionDeclarationInInfoPlist": true
      },
      "publication": {
        "metadata": { "description": "Mac-specific description" },
        "localizations": [],
        "screenshotPaths": ["AppStore/MacScreenshots"],
        "releaseAutomatically": false
      }
    }
  }
}
```

This is a release-fields example, not a replacement for an app's existing privacy,
age-rating, commercial, or subscription declarations. Keep those declarations.
Shared `publication` fields are inherited; platform objects merge recursively and
arrays replace shared arrays. If using `localizations`, override those listings
rather than `metadata`, or set `localizations: []` to use the metadata fallback.
The form editor saves listing/review edits to the displayed platform in schema 2;
Advanced JSON exposes schemes, source paths, defaults, and platform overrides.
Legacy schema 1 remains a single selected scheme.

Successful platform releases record source and effective publication fingerprints
in `~/Library/Application Support/DevManagement/ReleaseHistory`. Unchanged platforms
are deselected on opening Publish and skipped again when executing. `sourcePaths`
contains project-relative files/directories, including shared sources/resources and
build configuration that affects that platform. A shared version-only file may be
excluded so bumping one shared counter does not republish an unchanged platform.
Without explicit paths the whole repository is scanned conservatively (excluding
build outputs, generated Xcode containers, and documentation). A new installation,
a missing receipt, or a reused build with unverifiable original sources has no
trusted baseline: the selected platform remains eligible, rather than being silently
skipped. Source changes with an already-uploaded version/build fail with an explicit
version-bump instruction. Publishing itself never increments versions.

All targets resolve their own Release build settings before publishing. Native Mac
archives use `generic/platform=macOS`, explicit application and installer identities,
Mac App Store profiles, and `.pkg` export. Before submission the tool rereads Apple's
version, build/prerelease version, listing, processed screenshots, and review details,
prints a checklist, and aborts if required fields are missing. Promotional text and
marketing URL are optional. Mac screenshots must use `APP_DESKTOP`. The submit step
then polls the actual version/build until Apple confirms a review/release state.
A sent request without a confirmed state is not reported as successful publication.
App Sandbox is validated from the signed archive; app-specific network, Keychain,
and Info.plist encryption requirements are opt-in assertions, never automatic edits.

Run these commands directly through the installed app executable:

```sh
"/Applications/Development Management.app/Contents/MacOS/Development Management" doctor --app-id 6822605869
"/Applications/Development Management.app/Contents/MacOS/Development Management" status --app-id 6822605869 --platform MAC_OS
"/Applications/Development Management.app/Contents/MacOS/Development Management" dry-run --project /path/to/app --platform MAC_OS --app-id 6822605869
```

Doctor/status query both platforms by default and report builds, version states,
and missing fields. Dry-run resolves the existing Xcode schemes and release plan;
with `--app-id` it also queries the selected platforms. These commands do not launch
monitoring, archive, upload, submit, change versions, or mutate ASC. Dry-run requires
an already generated Xcode project; regenerate a stale project separately. Credentials
come from the default Publishing settings and Keychain, or explicit `--issuer-id`,
`--key-id`, and `--private-key-path` arguments. Secrets are never printed. API/config
failures exit nonzero; doctor missing-field findings are reported as diagnostics.

## SlateWifi audit (2026-10-16)

The saved October 14 run selected `SlateWiFiIOS` 1.0.10 (11). The old tool executed
only that scheme and had no multi-platform configuration, coordinator, source
receipts, doctor, or dry run. Mac archive/export/profile/installer signing, upload,
platform-filtered processing, metadata/review reconciliation, screenshots (reservation,
checksum commit, processing), and review-submission endpoints already existed. They
were never invoked for the Mac platform. Build/upload subprocess failures already
propagated; the incident was omitted work, not a swallowed Mac upload error.

A live read-only doctor query confirmed app 6822605869 had zero Mac TestFlight builds,
macOS 1.0 in PREPARE_FOR_SUBMISSION, no attached build or processed desktop screenshots,
and missing copyright, listing text/support URL, and App Review contacts/notes/sign-in
answer. `SlateWiFiMacStore` has Sandbox, network client, and the same credentials
Keychain group as iOS. Its Mac Info.plist lacks `ITSAppUsesNonExemptEncryption`; the
existing publishing manifest supplies an explicit ASC encryption declaration.
The existing hardware review notes had no demonstration URL. A real accessible
hardware demo must be supplied; the tool cannot manufacture review evidence.

Apple does not allow deleting an app platform once a build has been uploaded.
Leaving the rejected iOS record in ASC does not require publishing it during a
Mac-only release. The platform selector and Mac-only default control future work.

The audit also found the shared certificate picker accepted legacy iPhone-only
Distribution certificates on the Mac path. Mac application signing now selects
Apple Distribution exclusively; installer signing remains separate. The installed
Xcode 27.0.5 uploader's own `--help` confirms `.pkg` support and the modern
`--upload-package <file>` / `--validate-app <file>` syntax without a platform flag.
The old `-t macos` syntax belongs to legacy altool; it is not added to this uploader.

References: [Apple platform deletion rules](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/),
[build platform filters](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds),
and [Mac screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Screenshot content validation and repair (2.4.8)

A screenshot is ready only after pixel validation, accepted display dimensions,
and content checks. Both Publish and Upload to TestFlight stop if any supported
screenshot family fails or is unavailable. The file path and display type appear
in readiness and the publishing error. Invalid supplied files are reported rather
than silently discarded. A valid iPhone image cannot hide a failed iPad capture.

The validator decodes the image and measures a 256×256 sample: luminance mean,
variance, near-black/white coverage, and the largest quantized RGB color bucket.
Variance below 4 (on the 0–255 scale), or at least 95% black, white, or one near-color
bucket blocks upload. Decoded-image fingerprints reject duplicate content within
one locale/display set, including differently named copies. Reusing a screenshot
in a different localization is allowed. All candidates are checked before any
screenshot-set deletion or reservation; the uploader checks again before each
asset reservation. Localized fallback images go through the same gate.

OCR catches known empty-vault and unlock screens. It cannot identify every app's
login or splash screen. Inspect the preview and configure **Required content text**
for a phrase visible only after the desired real content is ready. This matches
Apple's [Guideline 2.3.3](https://developer.apple.com/help/app-review/guideline-reference/2-3-3-screenshots):
show the app in use. Automated validation is not a substitute for that inspection.

### Capture and demo configuration

Simulator images are captured directly with `simctl io <selected-UDID> screenshot`.
There is no phone-to-iPad scaling or padding. The target's supported device families
select separate iPhone/iPad simulators; a universal simulator build may be reused
for both. Watch/TV/Vision use their own family/scheme. Local PNG/JPEG files and
cached captures use the same validator. Only native Mac window capture uses a
16:10 canvas; the original Mac window is also checked for blank content before
compositing, so the backdrop cannot conceal a black window.

Capture waits for `simctl bootstatus -b`, launches the chosen app on the chosen
UDID, then samples every two seconds until two successive frames pass validation.
The default retry budget is 30 seconds, configurable up to 60 seconds. Process
failures propagate. Pixel/readiness failures retry and report their file/type.
Prepared simulator captures do not reinstall or terminate the existing app, so
an unlocked content screen is preserved. Automatic captures install the simulator
build and launch it with the configured arguments. The existing
`-AppStoreScreenshotFixture` convention remains supported.

**Publishing Configuration → Screenshots** provides per-family demo launch
arguments (one argument per line) and required content text. These settings use a
Debug simulator build, preserve the app version/build, and never change production
privacy protection. The app itself must implement the supplied launch mode.
For example, an app with an implemented `-DemoMode YES` content fixture can use:

```json
"screenshotCapture": {
  "iPad": {
    "launchArguments": ["-DemoMode", "YES"],
    "readyText": "Sample vault entries",
    "timeoutSeconds": 40
  }
}
```

This object belongs under `publication`, including shared or platform-specific
publication in schema 2. Family keys are `iPhone`, `iPad`, `appleWatch`, `appleTV`,
`appleVisionPro`, and `mac`. Mac capture accepts the demo arguments and content-text
check, but uses ScreenCaptureKit rather than the simulator retry loop.
After changing capture settings, use **Regenerate screenshot preview** to discard
cached generated images. Supplied screenshot files remain authoritative.

### KeyPassX investigation, October 16, 2026

The historical cache contains a reproducible validation failure:

| Capture | Dimensions | Mean luminance | Variance | Near-black fraction |
| --- | --- | --- | --- | --- |
| 0.1.32 (33), iPad Pro 13-inch M5 | 2064×2752 | 0.01158 | 0.63929 | 99.974% |
| 0.1.34 (35), same iPad | 2064×2752 | 252.80104 | 126.64103 | 0% |

Files are under
`~/Library/Caches/DevManagement/AppStoreScreenshots/45299918-C2BD-4ABE-8935-C4B41615E870/<version-build>/Default-v1/Screenshots/`.
The first image visibly shows a black loading frame with a small spinner. The
later image shows KeyPassX's empty-vault welcome screen. Neither is suitable store
content. The 0.1.34 publish log at `2026-10-14T19:08:38Z` says:

```text
Found 3 valid local or cached screenshot(s).
Prepared 3 App Store screenshot(s).
Keeping 1 existing screenshot(s) for APP_IPAD_PRO_3GEN_129.
```

Previously “valid” meant accepted dimensions only. Apple's COMPLETE asset state
also only confirmed processing, not visible content. Therefore the UI could show
a newer preview while Publish retained the earlier remote screenshot. This
retention and the missing pixel gate explain how a bad capture survives retries;
the exact remote image's provenance was not downloaded/verified during this audit.

Booting `EFD140A2-A821-460A-9EE5-C0C369433C1D` and launching the already installed
0.1.34 (35) simulator app produced the welcome screen at both 3 and 15 seconds,
not the historical black frame. The historical timing/GPU transition is therefore
intermittent; the audit does not claim a proven Metal defect. The cache and installed
bundle confirm `UIDeviceFamily = [1, 2]` and the correct app/version. Source inspection
found an inactive/authentication privacy overlay, but no `isCaptured` handler;
the visible historical spinner is not sufficient to attribute it to that overlay.
The old fixed three-second delay provided no rendered-content guarantee.

At the original investigation, KeyPassX's `-ui-test-vault YES` fixture created
sample entries but left the vault locked. The publisher recognized only
`-AppStoreScreenshotFixture`, so it never used that fixture. KeyPassX 0.1.39 now
supports the publisher's flag and opens sample content automatically; see
**Automatic demo content and recovery** below. The old binary still needs the
prepared-simulator workflow when repairing screenshots for that exact version.

### Repair KeyPassX 0.1.34 without a new build

1. Prepare the **iPad Pro 13-inch (M5)** simulator with KeyPassX 0.1.34 (35).
   The original Debug simulator app is still cached at
   `.../0-1-34-35/Default-v1/Build-iPhone/Build/Products/Debug-iphonesimulator/KeyPassXiOS.app`.
   Run it with `-ui-test-vault YES`, unlock the synthetic vault using its fixture
   password (`ui-test-password`), and leave the sample entry list visible.
2. In **Publishing Configuration → Screenshots**, choose that prepared iPad
   simulator. Leave its demo launch arguments empty for this prepared-screen
   capture, and set required content text to a visible sample entry (for example
   `Email`). Save. Use supplied screenshots or prepared content screens for other
   supported device families as needed.
3. In the Publish overview, choose **Regenerate screenshot preview**. Inspect the
   iPad content image. If other families fail validation, their failures still
   block ordinary Publish, but the targeted repair validates just the selected
   display type so iPad-only metadata repair remains possible.
4. Enter **0.1.34** in **App Store version to repair**, choose
   **APP_IPAD_PRO_3GEN_129**, and click **Replace screenshots on existing version**.
   It validates all selected assets first, resolves the existing editable iOS
   0.1.34 version, deletes/recreates only that display type's set in each existing
   localization, uploads reservation/chunks/checksum, and waits for COMPLETE.
   No archive, build upload, version creation, build attachment change, or review
   submission occurs. Retry this action after a transfer failure.
5. In App Store Connect, inspect the iOS 0.1.34 iPad screenshots in every locale,
   confirm build **35** remains attached, address any other review messages, and
   resubmit that version. The local project has since advanced to 0.1.39 (40), so
   ordinary Publish would target that newer version; use this repair action for
   the old version.

Ordinary Publish now retains remote screenshots only if their completed assets'
checksums/order match the validated local files. Different content is replaced.
The explicit replacement option forces deletion/recreation of matching display
sets, including when the old assets claim COMPLETE. Replacement is not atomic in
ASC: validation occurs first, but a network failure after deletion requires retry.

## Readiness layout (2.4.9)

Readiness cards show at most three lines of detail. **View details…** opens the
complete, selectable diagnostic text in a scrollable sheet with **Copy details**.
The readiness panel has its own bounded scroll area, leaving space for the
independently scrolling publishing columns and the fixed release footer, including
on shorter windows. A global screenshot validation failure is listed once instead
of being repeated under every device family. Screenshot validation remains a
publication blocker until the underlying content is corrected.

## Automatic demo content and recovery (2.5.0)

The KeyPassX capture failures after the validation update had a separate cause:
normal launches show a welcome/locked vault, and the existing `-ui-test-vault`
fixture only selected its sample file without unlocking it. Its Watch app also
required wrist authentication and had no sample data. Blocking those captures was
correct, but validation alone could not produce usable store screenshots.

KeyPassX now implements `-AppStoreScreenshotFixture` in Debug builds. The iOS/Mac
fixture opens an encrypted, temporary synthetic vault with isolated preferences;
iPad opens its sample Email entry. Watch opens the same kind of entry from an
in-memory synthetic snapshot, without pairing or reading stored credentials.
Release builds exclude this mode. Background locking remains active. The normal
UI renders the screenshots; no artificial screenshot canvas or privacy bypass is
used. iPad uses its supported larger-text launch setting for a readable capture.

The local KeyPassX publication configuration uses this setup:

```json
"screenshotCapture": {
  "iPhone": {
    "launchArguments": ["-AppStoreScreenshotFixture"],
    "readyText": "Email", "timeoutSeconds": 60
  },
  "iPad": {
    "launchArguments": ["-AppStoreScreenshotFixture",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"],
    "readyText": "Email", "timeoutSeconds": 60
  },
  "appleWatch": {
    "launchArguments": ["-AppStoreScreenshotFixture"],
    "readyText": "Email", "timeoutSeconds": 60
  }
}
```

Invalid generated cache files are deleted and recaptured on the next attempt.
Invalid supplied files remain blocking errors and are never deleted automatically.
A specific Watch `IXErrorDomain / Uninstall requested` installation race is retried
up to three times; other errors fail immediately. No simulator data is erased.
Watch welcome/wrist-lock screens are now rejected by the empty-screen detector.
The existing uniform-color, dimension, duplicate, and content-text gates remain.

To exercise the same capture pipeline without uploading or submitting anything:

```sh
"/Applications/Development Management.app/Contents/MacOS/Development Management" \
  capture-screenshots --project /path/to/app --platform IOS
```

This command regenerates previews, builds with scheme workflow actions removed,
prints validated file paths, and exits nonzero if any required family fails.
It does not require ASC credentials or change the managed app's version.

After reopening Publish, inspect all previews and choose **Publish** for the full
upload-and-submit workflow. Choose **Upload to TestFlight** only when you want to
stop before review. Normal publishing replaces different remote screenshot content and
reuses an already uploaded matching build. To repair a rejected older version
without a build upload, use **Replace screenshots on existing version**, verify
that the pictured UI matches that version, then resubmit it in App Store Connect.

Validation on 2026-10-16 used KeyPassX 0.1.39 (40) and the actual capture command:
all three required families passed pixel/dimension/OCR validation. The output was
1320×2868 (`APP_IPHONE_67`), 2064×2752 (`APP_IPAD_PRO_3GEN_129`), and 422×514
(`APP_WATCH_ULTRA`). The images show the sample vault list and masked Email entry
details. No screenshots were uploaded or review submissions changed during this
verification. Development Management passed 516 unit tests; KeyPassX passed 119
package tests including localization parity and the fixture unlock/lock regression.


## Optional review notes (2.5.1)

The release-input validator incorrectly required `review.notes`, even though the
Publish overview did not. This stopped KeyPassX's TestFlight action before any
archive or upload. The ASC submission checklist also imposed the same incorrect
requirement. Both now allow missing, empty, or whitespace-only notes, consistent
with [Apple's App Store review details documentation](https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-details).
Review contacts remain required, as do demo credentials when sign-in is required.
Configured hardware demo videos are still required before review submission and
must appear in the submitted notes. No placeholder review text is generated.


## First-release workflow and completion display (2.5.2)

The first-release UI previously hid Publish until a matching TestFlight build
existed, forcing two runs even though the publishing service already supported
uploading, processing, and submitting in one run. That gate is removed. Publish
still waits for Apple's processing and verifies the submitted version's state;
a TestFlight-only run never silently submits for review.

A successful TestFlight-only run now has a TestFlight-specific heading, marks
App Store setup complete unless it was actually deferred, and marks Review as
skipped. The finished progress label says **Completed** instead of looking stuck
at step 4 of 5. **Continue to App Review…** returns to the publishing overview for
review and confirmation; it does not submit automatically.

### Mac store configuration and screenshot identity

An explicit platform `configuration` is used for both resolving build settings and
archiving. For example, `MAC_OS: {"scheme":"MyMacApp","configuration":"AppStore"}`
can select a sandboxed store build with the shared iOS bundle identifier while
Debug/Release retain a separate local Mac identity. Legacy single-platform projects
still default to Release. The managed app's version and build are preserved.

Mac previews resolve the Debug configuration's own bundle identifier and wait for
two validated content frames using the configured `screenshotCapture.mac` launch
arguments and `readyText`. The preview and the archive can therefore have different
bundle identifiers. Screenshot caches are separated by release platform so
regenerating Mac screenshots cannot remove the iPhone/iPad/Watch set.

For KeyPassX, the local publishing manifest now selects `KeyPassXMac / AppStore`
and defaults to `MAC_OS` while iOS 0.1.39 remains in review. The Mac configuration
uses the shared store identifier, sandbox, user-selected file access, network
client, shared Keychain group and the publisher's existing encryption declaration.
Its Debug preview uses `-AppStoreScreenshotFixture` and requires `Email` on screen.
Choose **Publish**, not **Upload to TestFlight**, to continue through review.
A draft named 1.0 is updated to the source marketing version when the Mac release
is prepared; publishing does not rewrite source version numbers to match a draft.

### Empty draft versions and source readiness

A platform's `PREPARE_FOR_SUBMISSION` version with no attached build does not
set a minimum source version. For example, a newly added Mac draft named `1.0`
can be prepared as source version `0.1.40 (41)` without changing the source.
The readiness check still blocks older source versions when the selected version
has a build, is in review or released, or when that platform has a newer approved
or active review version. The existing version setup updates the reusable draft's
version string during Publish.

### Mac sandbox entitlements and provisioning profiles

The profile validator applies macOS-specific rules when inspecting a Mac archive.
Documented unrestricted sandbox and Hardened Runtime entitlements, including
`com.apple.security.files.bookmarks.app-scope` and document-scoped bookmarks, stay
in the app signature but do not have to appear in its distribution profile.
They are not Developer Portal capabilities to enable. See Apple's
[TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

Restricted iCloud, push and Keychain capabilities still require profile
authorization. Unknown keys are not silently excluded, and the Mac exemptions
do not apply to iOS. Matching existing Mac profiles can be reused without
creating another profile merely because they omit a sandbox entitlement.
Retries preserve the managed app's version/build and reuse its saved archive.

## Supplied screenshot sets stay ordered and complete (2.5.7)

Files under `screenshotPaths` (and screenshot folders discovered in the project)
are now ordered by path with numeric awareness, so `01-vault.png` precedes
`02-entry.png` and `10-settings.png` in every publish and in the
**Replace screenshots on existing version** action. Cached automatic captures
are used only for device families that have no supplied file. Previously the
cache for the same version/build was appended to the supplied set, so a stale
single capture could travel with a curated iPad set, and enumeration order
decided the App Store order.

KeyPassX supplies `Screenshots/<locale>/iPad-13/` and `Screenshots/<locale>/iPhone-69/`
for `en-US` and `he`, generated by its `scripts/capture-app-store-screenshots.sh`
from the Debug fixture's `-AppStoreScreenshotScene` launches (vault, entry,
generator, search, settings, autofill). Its manifest sets `replaceScreenshots`
to `true`, so each publish deletes and recreates the matching display sets
instead of keeping or appending. Watch continues to use the automatic fixture
capture. No upload happens outside Publish or the repair action.
