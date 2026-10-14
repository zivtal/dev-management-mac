# Automatic App Privacy publishing for collected data — design

Approved in conversation 2026-10-14. Extends the existing no-data App Privacy
automation so a reviewed collected-data declaration is also published through
the Apple web session (or the legacy Fastlane session) instead of requiring the
questionnaire to be completed by hand in App Store Connect.

## Why

Apple has no public API for App Privacy. Development Management already
publishes a **Data Not Collected** declaration through Apple's private
`appDataUsages` endpoints. A collected-data declaration uses the same endpoints
with one record per data type, purpose, and protection, which is also the shape
Fastlane's `upload_app_privacy_details_to_app_store` sends. What was missing was
the per-type detail in the draft: purposes, whether data is linked to the user,
and whether it is used for tracking.

## Model

- `AppStorePrivacyDataUse` (new, Codable): `category` (Apple category id such
  as `USER_ID`), `purposes` (Apple purpose ids), `linkedToUser`, `usedForTracking`.
- `AppStorePrivacyDraft.dataUses: [AppStorePrivacyDataUse]?` (new, optional so
  older manifests still decode). `dataTypes` stays the group checklist and is
  derived from the groups of the selected categories whenever uses change.
- `AppStorePrivacyCatalog` (new): Apple's category ids grouped under the 14
  group names already used by the draft, the six purpose ids, and the four
  protection ids, each with an English title used as the localization key.
- A draft is **complete** when it does not collect data, or when it has at least
  one use and every use names at least one purpose. Completeness is the gate for
  automation; nothing is assumed for a missing purpose.

## Usage plan

`AppStorePrivacyUsagePlan.records(for:)` turns a complete draft into
`(category, purpose, dataProtection)` records exactly as Fastlane does: for each
use and each purpose one record with `DATA_LINKED_TO_YOU` or
`DATA_NOT_LINKED_TO_YOU`, plus one with `DATA_USED_TO_TRACK_YOU` when tracking
is declared. A no-data draft yields the single `DATA_NOT_COLLECTED` record. An
incomplete collected-data draft throws `collectedDataNeedsDetails`.

The same plan feeds both publishers:

- Web session: the records are passed into the page script. It reads the
  existing usages, publishes immediately when they already match, refuses to
  replace existing collected-data answers with a no-data declaration (unchanged
  rule), otherwise deletes the existing records and creates the planned ones,
  then flips the publish state and verifies it.
- Fastlane: `payload(for:)` emits one usage per data use with its purposes and
  protections; the no-data payload is unchanged.

## Policy and flow

`AppStorePrivacyConfigurationPolicy` treats a complete collected-data draft like
a no-data draft: it needs the automatic-publishing authorization and becomes
`automaticallyAuthorized`. An incomplete collected-data draft keeps today's
manual path (`needsManualConfirmation`, confirmed by hand). The publishing flow
is unchanged except that it rejects an authorized-but-incomplete draft before
contacting Apple.

## Editor

`PublishingPrivacyDraftFields` gains the per-category editor: each group is a
disclosure listing Apple's categories; a selected category shows purpose
toggles, "Linked to the user's identity", and "Used for tracking". The
authorization toggle appears for any complete draft; the manual-confirmation
toggle remains for incomplete collected-data drafts.

## OpenAI draft

The compliance schema gains `privacy.dataUses` with the same fields, restricted
to Apple's ids. The prompt asks for purposes, linking, and tracking per category
only when repository evidence supports them, and leaves purposes empty (making
the draft incomplete and `privacyEvidenceSufficient` false) otherwise.

## Tests

Usage-plan records and Fastlane payloads for no-data, linked, not-linked, and
tracking cases; completeness; catalog group lookup; legacy manifest decoding;
policy states for complete and incomplete collected drafts with and without
authorization.
