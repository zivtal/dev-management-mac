# One-click App Store publishing

Development Management inspects each managed iOS project when **Publish** is
clicked. A local Xcode StoreKit configuration (`*.storekit`) is the preferred
source for subscription groups, products, periods, prices, and localizations.

The optional `app-store-publishing.json` file belongs in the managed app's root
folder. It supplies production settings that aren't represented by StoreKit.
Financial, legal, and age-rating declarations are never guessed by AI.

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
  "subscriptions": {
    "baseTerritory": "ISR",
    "availableInAllTerritories": true,
    "reviewScreenshot": "Screenshots/subscription-review.png"
  }
}
```

Open **Publish… → Per-App Configuration…** to create, edit, validate, and save
this file without leaving Development Management. Account-wide defaults live in
Publishing Settings; values in this file override them for this app. API keys,
private keys, and demo-account passwords are never written to the file.

Publishing Settings supports multiple named App Store Connect API profiles. Each
managed app selects either the default API or one additional profile in its
Publish window. Issuer and key identifiers are stored in app preferences, while
each profile's private key is kept under a distinct macOS Keychain account.
Removing a profile returns apps that selected it to the default API.

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

When `metadata` is omitted, Publish generates the listing fields with OpenAI.
Descriptions cover verified features, audience, value, privacy-relevant behavior,
and named third-party providers found in the supplied project documentation.
The remaining app-specific settings are deterministic and manually editable; AI
never chooses content-rights declarations, public URLs, legal text, pricing,
availability, family sharing, age ratings, review credentials, release behavior,
or offer-code terms.

Support, marketing, privacy-policy, privacy-choices, and Terms of Use URLs are
manual fields. Support and privacy-policy URLs are required, and Terms of Use is
also required for apps with subscriptions. Marketing and privacy-choices URLs
remain optional. Publish appends the manually supplied Privacy Policy and Terms
of Use links to every localized description while preserving Apple's 4,000
character limit; OpenAI does not create or replace those links.

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
When all-territory availability is enabled, the publisher applies Apple's
equalized price point in every available territory.

First publication reconciles app information, availability, a free app price
when explicitly requested, subscription groups and products, current v2
versioned localizations, paywall review screenshots, prices, and review items.
When an older app version is already published, those durable resources are
preserved: Publish handles only the new App Store version metadata, screenshots,
build upload, attachment, and review submission.

## Publish pipeline

**Publish** performs the complete automatable release pipeline in this order:

1. Discover StoreKit products and deterministic per-app configuration.
2. Validate every configured public support, marketing, privacy, and terms URL
   before spending time on an archive that cannot be submitted.
3. Prepare or capture App Store screenshots for each supported simulator family.
4. Look for the exact selected marketing version and build in TestFlight. When
   it is already present, reuse it and skip the archive and upload. Otherwise,
   archive and export the selected iOS scheme.
5. When an archive is required, read its bundle identifier, marketing version,
   and build number. These archive values remain authoritative when a scheme
   pre-action increments the source version during the build. A reused
   TestFlight build is confirmed as fully processed before the App Store version
   is changed.
6. When an older app version is still in review and the user confirms an
   update, cancel that review submission only after the replacement archive has
   succeeded. The canceled editable version record is reused for the newer
   marketing version, and all submission items are submitted again.
7. Create or update the App Store version and reconcile its metadata,
   availability, pricing, subscriptions, and screenshots. When an archive was
   required, validate and upload its IPA.
8. Wait for Apple to process the exact archived build and attach it to the exact
   archived marketing version.
9. Add the build to every internal TestFlight group. If the app has no internal
   group, create an `Internal Testing` group with access to all builds. App Store
   Connect users still need to be added as testers once; Publish does not invite
   people or change account roles. Groups with automatic distribution already
   receive every processed build and are not manually reassigned. For manually
   managed groups, existing access is confirmed before requesting an assignment.
10. Upload configured demo videos and documents to App Review, wait for Apple to
   finish processing each attachment, and submit the complete version.

**Upload to TestFlight** is a separate action. It archives, validates, uploads,
waits for processing, and enables the exact build for every internal TestFlight
group without creating an App Store version or submitting for review. It is
idempotent: when the exact marketing version and build are already present, it
only confirms internal-group availability. The action requires a local version
and build plus a complete App Store Connect API configuration, but it does not
wait for the full App Store release-readiness snapshot. The API key and existing
TestFlight build are verified when the upload workflow starts.

When the managed folder contains a root `project.yml` and the selected container
is a root-level Xcode project, Development Management regenerates the project
with XcodeGen immediately before a direct build or archive. Newly added source
files are therefore included before a scheme pre-action can advance the app
version. If a command still fails, the alert shows the relevant compiler or
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
and requested base price. Saved price edits update `app-store-publishing.json`
and are applied to App Store Connect by the next Publish run. Redeem Codes shows
existing production offers and creates either Apple one-time code batches or a
custom reusable code, using the selected subscription. Switching tabs preserves
the release window layout; code creation has its own in-tab action, while the
footer **Upload to TestFlight** and **Publish** or **Update** actions belong to
the release workflow. Publish always submits for App Review; the TestFlight
action is the explicit upload-only path. The window also remains open when
another application or Development Management window receives focus.

When App Store Connect reports an older app version in an active review state,
the release action is labeled **Update** and identifies that version. The final
confirmation explains that the active submission and all of its items will be
canceled, the editable version will be replaced, and the review queue will start
again. If no app version is in review, Update uploads and submits normally. The
same local version and build already submitted to Apple remain blocked to avoid
a duplicate submission. A matching build that is only in TestFlight is not
blocked: Publish attaches it to the App Store version and submits it without
another archive or upload.

Publish stays open after confirmation and presents five understandable stages:
Prepare, Build, App Store setup, TestFlight, and Review. The current task,
overall completion, elapsed time, and friendly explanation remain visible.
Technical command output is available on demand. The same determinate progress
appears in the menu bar, where **View** reopens the full release window. A failed
run keeps its exact failure step and offers a direct return to the readiness
screen; a successful run shows the archived version, build, and destination.

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
- a named custom code containing 1–64 letters or digits, with 1–25,000
  redemptions per batch and an optional expiration date.

Offer duration, new/existing/expired subscriber eligibility, introductory-offer
interaction, renewal behavior, product, code quantity, and expiry are chosen in
the app. Custom-code generation replaces the setup form with the reusable code
and a copy action. One-time batches prompt for a destination before the
production request and save Apple's returned CSV directly to disk. Code creation
is unavailable until App Store Connect reports at least one app version ready
for distribution and reports the selected
subscription as approved; the same checks are repeated by the service immediately
before a production request. New free offers include a price relationship for
every territory currently enabled for the subscription, as required by App Store
Connect. The inline territory-price resources use App Store Connect local IDs
prefixed with `$`, and the offer's price relationships reference those same IDs.

Apple still requires the initial App Store Connect app record, signed legal
agreements, banking and tax information for paid content, App Privacy answers,
any compliance declarations that aren't exposed through the API, and at least
one eligible App Store Connect user in an internal TestFlight group. Publish
does not fabricate legal answers, accept agreements, invite users, reply to App
Review messages, or create missing public support and privacy websites.
