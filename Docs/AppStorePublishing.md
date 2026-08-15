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
    "submitForReview": true,
    "releaseAutomatically": false,
    "screenshotPaths": ["Screenshots", "Marketing/iPhone-6.7.png"],
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

When `metadata` is omitted, Publish generates the four fields with OpenAI. The
remaining app-specific settings are always deterministic and manually editable;
AI never chooses pricing, availability, family sharing, age ratings, review
credentials, release behavior, or offer-code terms.

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
the app. One-time values are downloaded from App Store Connect and saved to a
user-selected CSV file. Apple requires the app to be ready for distribution and
the subscription to be approved before production codes can be generated.

Apple still requires the initial App Store Connect app record, signed legal
agreements, banking and tax information for paid content, App Privacy answers,
and any compliance declarations that aren't exposed through the API.
