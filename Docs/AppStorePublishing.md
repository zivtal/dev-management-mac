# One-click App Store publishing

Development Management inspects each managed iOS project when **Publish** is
clicked. A local Xcode StoreKit configuration (`*.storekit`) is the preferred
source for subscription groups, products, periods, prices, and localizations.

The optional `app-store-publishing.json` file belongs in the managed app's root
folder. It supplies production settings that aren't represented by StoreKit.
Saved manifest values are authoritative. For a new app, the publishing editor
can ask OpenAI to prepare a conservative, evidence-backed draft from bounded
`README.md` and project-manifest excerpts. Every generated value is placed in a
normal editable field and must be reviewed and saved before either release
action can start. OpenAI never changes fields during Upload or Publish.

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
Connect API. For an explicitly reviewed **Data Not Collected** declaration,
Development Management can publish the answer with Fastlane's authenticated
App Store Connect web session. Publishing Settings stores the Apple ID in app
preferences and the `FASTLANE_SESSION` value in Keychain; the Apple ID password
is never stored. Run the copied `fastlane spaceauth` command, paste the returned
session, and authorize the per-app declaration in App Setup. A successful run
records `publishedAt` in the manifest and does not repeat the operation unless
the privacy draft changes. Collected-data declarations still require manual
purpose, linking, and tracking answers in App Store Connect, followed by the
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

## Shared release pipeline

**Upload to TestFlight** and **Publish** run the same setup pipeline in this
order:

1. Discover StoreKit products and deterministic per-app configuration.
2. Publish an authorized no-data App Privacy declaration when it has not already
   been published.
3. Validate every configured public support, marketing, privacy, and terms URL
   before spending time on an archive that cannot be submitted.
4. Prepare or capture App Store screenshots for each supported simulator family.
5. Look for the exact selected marketing version and build in TestFlight. When
   it is already present, reuse it and skip the archive and upload. Otherwise,
   archive and export the selected iOS scheme.
6. When an archive is required, read its bundle identifier, marketing version,
   and build number. These archive values remain authoritative when a scheme
   pre-action increments the source version during the build. A reused
   TestFlight build is confirmed as fully processed before the App Store version
   is changed.
7. Create or update the App Store version and reconcile localized listing text,
   app categories and declarations, availability, app pricing, subscription
   groups/products/localizations/prices, and localized screenshots. When an
   archive was required, validate and upload its IPA.
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

For a first release, the footer shows only **Upload to TestFlight** until Apple
has processed the exact local version and build. The App Store action then
appears as **Submit for Review**. Existing released apps continue to show the
normal update action.

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
