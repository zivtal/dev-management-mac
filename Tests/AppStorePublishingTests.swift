import CryptoKit
import XCTest
@testable import DevManagement

final class AppStorePublishingTests: XCTestCase {
    func testPublishingWindowLayoutExpandsAcrossTheAvailableWidth() {
        XCTAssertEqual(PublishingWindowLayout(width: 899), .singleColumn)
        XCTAssertEqual(PublishingWindowLayout(width: 900), .twoColumns)
        XCTAssertEqual(PublishingWindowLayout(width: 1_499), .twoColumns)
        XCTAssertEqual(PublishingWindowLayout(width: 1_500), .threeColumns)
    }

    func testOpenAIRequestUsesStrictStructuredOutputAndDisablesStorage() throws {
        let body = OpenAIStoreMetadataService.requestBody(
            model: "gpt-5.6-luna",
            prompt: "Project information"
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testOpenAIResponseDecodesStructuredMetadata() throws {
        let generated = AppStoreMetadata(
            description: "A useful application.",
            keywords: "useful,application",
            promotionalText: "Try it today.",
            whatsNew: "Performance improvements."
        )
        let generatedData = try JSONEncoder().encode(generated)
        let generatedJSON = try XCTUnwrap(String(data: generatedData, encoding: .utf8))
        let response: [String: Any] = [
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": generatedJSON]]
            ]]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response)

        XCTAssertEqual(try OpenAIStoreMetadataService.decodeMetadata(from: responseData), generated)
    }

    func testGeneratedMetadataIsLimitedToAppStoreLengths() {
        let metadata = AppStoreMetadata(
            description: String(repeating: "d", count: 4_100),
            keywords: String(repeating: "é", count: 60),
            promotionalText: String(repeating: "p", count: 200),
            whatsNew: String(repeating: "n", count: 4_100),
            subtitle: String(repeating: "s", count: 40),
            primaryCategory: "FINANCE",
            secondaryCategory: ""
        ).normalized()

        XCTAssertEqual(metadata.description.count, 4_000)
        XCTAssertLessThanOrEqual(metadata.keywords.lengthOfBytes(using: .utf8), 100)
        XCTAssertEqual(metadata.promotionalText.count, 170)
        XCTAssertEqual(metadata.whatsNew.count, 4_000)
        XCTAssertEqual(metadata.subtitle?.count, 30)
        XCTAssertEqual(metadata.primaryCategory, "FINANCE")
        XCTAssertNil(metadata.secondaryCategory)
    }

    func testOpenAIRequestGeneratesEditableListingAndCategories() throws {
        let body = OpenAIStoreMetadataService.requestBody(model: "model", prompt: "prompt")
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["subtitle"])
        XCTAssertNotNil(properties["primaryCategory"])
        XCTAssertNotNil(properties["secondaryCategory"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("primaryCategory"))
    }

    func testOpenAIRequestGeneratesOneEditableListingForEveryDetectedLanguage() throws {
        let body = OpenAIStoreMetadataService.localizedRequestBody(
            model: "model",
            prompt: "prompt",
            locales: ["en-US", "he"]
        )
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let localizations = try XCTUnwrap(properties["localizations"] as? [String: Any])
        XCTAssertEqual(localizations["minItems"] as? Int, 2)
        XCTAssertEqual(localizations["maxItems"] as? Int, 2)
        let items = try XCTUnwrap(localizations["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let locale = try XCTUnwrap(itemProperties["locale"] as? [String: Any])
        XCTAssertEqual(locale["enum"] as? [String], ["en-US", "he"])
    }

    func testDiscoversAppLanguagesFromXcodeAndLocalizationResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectLocalizationTests-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Resources/fr.lproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        developmentRegion = en;
        knownRegions = (Base, en, de);
        """.write(
            to: projectDirectory.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        let catalog = #"{"sourceLanguage":"en","strings":{"title":{"localizations":{"he":{}}}}}"#
        try catalog.write(
            to: root.appendingPathComponent("Localizable.xcstrings"),
            atomically: true,
            encoding: .utf8
        )

        let locales = ProjectLocalizationDiscoveryService().discover(
            project: managedProject(at: root),
            defaultLocale: "es-ES"
        )
        XCTAssertEqual(Set(locales), Set(["de-DE", "en-US", "es-ES", "fr-FR", "he"]))
        XCTAssertEqual(locales.first, "es-ES")
    }

    func testScreenshotDimensionsMapToAppStoreDisplayTypes() {
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(width: 1_320, height: 2_868),
            "APP_IPHONE_67"
        )
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(width: 2_752, height: 2_064),
            "APP_IPAD_PRO_3GEN_129"
        )
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 800, height: 600))
    }

    func testAppStoreConnectJWTContainsExpectedClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try AppStoreConnectService.jwt(
            issuerID: "issuer-id",
            keyID: "KEY123",
            privateKey: privateKey,
            now: now
        )
        let components = token.split(separator: ".")
        XCTAssertEqual(components.count, 3)

        let header = try decodedJWTComponent(String(components[0]))
        let payload = try decodedJWTComponent(String(components[1]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY123")
        XCTAssertEqual(payload["iss"] as? String, "issuer-id")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(payload["exp"] as? Int, 1_800_001_100)
    }

    func testLegacyPreferencesDecodeWithoutPublishingFields() throws {
        let data = Data(#"{"automationEnabled":true,"reinstallAfterDays":3,"launchAtLogin":true,"pollIntervalSeconds":300}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertNil(preferences.openAIModel)
        XCTAssertNil(preferences.appStoreConnectIssuerID)
        XCTAssertNil(preferences.appStoreSubmitForReview)
        XCTAssertNil(preferences.appStoreReviewEmail)
    }

    func testDiscoversSubscriptionsFromStoreKitAndAppliesProjectDefaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreKitDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeKit = #"""
        {
          "subscriptionGroups": [{
            "name": "Premium",
            "localizations": [{"locale":"en_US","displayName":"Premium"}],
            "subscriptions": [{
              "referenceName": "Premium Monthly",
              "productID": "com.example.app.premium.monthly",
              "recurringSubscriptionPeriod": "P1M",
              "displayPrice": "9.90",
              "familyShareable": true,
              "groupNumber": 1,
              "localizations": [{
                "locale": "en_US",
                "displayName": "Premium Monthly",
                "description": "All premium features for one month."
              }]
            }]
          }]
        }
        """#
        let manifest = #"""
        {
          "schemaVersion": 1,
          "publication": {
            "locale": "he",
            "supportURL": "https://example.com/support",
            "submitForReview": false,
            "metadata": {
              "description": "Manual description",
              "keywords": "manual,keywords",
              "promotionalText": "Manual promotion",
              "whatsNew": "Manual release notes"
            }
          },
          "application": {
            "primaryCategory": "FINANCE",
            "contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT",
            "isFree": true,
            "baseTerritory": "USA",
            "availableInAllTerritories": true,
            "ageRating": {"gambling": false, "advertising": false}
          },
          "subscriptions": {
            "baseTerritory": "ISR",
            "availableInAllTerritories": true,
            "reviewScreenshot": "Screenshots/subscription-review.png"
          }
        }
        """#
        try storeKit.write(
            to: root.appendingPathComponent("Products.storekit"),
            atomically: true,
            encoding: .utf8
        )
        try manifest.write(
            to: root.appendingPathComponent("app-store-publishing.json"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = try StoreKitSubscriptionDiscoveryService().discover(
            project: managedProject(at: root),
            defaultLocale: "en-US"
        )
        XCTAssertEqual(catalog.subscriptionCount, 1)
        XCTAssertEqual(catalog.publication?.locale, "he")
        XCTAssertEqual(catalog.publication?.metadata?.description, "Manual description")
        XCTAssertEqual(catalog.application?.primaryCategory, "FINANCE")
        XCTAssertEqual(catalog.application?.ageRating?["gambling"], .bool(false))
        let subscription = try XCTUnwrap(catalog.groups.first?.subscriptions.first)
        XCTAssertEqual(subscription.period, "ONE_MONTH")
        XCTAssertEqual(subscription.basePrice, "9.90")
        XCTAssertEqual(subscription.baseTerritory, "ISR")
        XCTAssertEqual(subscription.availableInAllTerritories, true)
        XCTAssertEqual(subscription.reviewScreenshot, "Screenshots/subscription-review.png")
        XCTAssertEqual(subscription.localizations?.first?.locale, "en-US")
    }

    func testSubscriptionOfferCodeBodiesUseCurrentAppStoreConnectShapes() throws {
        let offer = SubscriptionOfferConfiguration(
            referenceName: "Friends 2026",
            duration: .oneMonth,
            customerEligibilities: [.new, .expired],
            stackWithIntroductoryOffer: false,
            autoRenewEnabled: true
        )
        let offerBody = AppStoreConnectService.subscriptionOfferCreateBody(
            offer,
            subscriptionID: "subscription-id"
        )
        let offerData = try XCTUnwrap(offerBody["data"] as? [String: Any])
        let offerAttributes = try XCTUnwrap(offerData["attributes"] as? [String: Any])
        let offerRelationships = try XCTUnwrap(offerData["relationships"] as? [String: Any])
        let prices = try XCTUnwrap(offerRelationships["prices"] as? [String: Any])
        XCTAssertEqual(offerData["type"] as? String, "subscriptionOfferCodes")
        XCTAssertEqual(offerAttributes["offerMode"] as? String, "FREE_TRIAL")
        XCTAssertEqual(offerAttributes["duration"] as? String, "ONE_MONTH")
        XCTAssertEqual(offerAttributes["customerEligibilities"] as? [String], ["EXPIRED", "NEW"])
        XCTAssertEqual(prices["data"] as? [[String: String]], [])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let expiration = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 15)))
        let oneTimeBody = AppStoreConnectService.oneTimeOfferCodeCreateBody(
            offerID: "offer-id",
            numberOfCodes: 500,
            expirationDate: expiration,
            calendar: calendar
        )
        let oneTimeData = try XCTUnwrap(oneTimeBody["data"] as? [String: Any])
        let oneTimeAttributes = try XCTUnwrap(oneTimeData["attributes"] as? [String: Any])
        XCTAssertEqual(oneTimeAttributes["numberOfCodes"] as? Int, 500)
        XCTAssertEqual(oneTimeAttributes["expirationDate"] as? String, "2026-12-15")
        XCTAssertEqual(oneTimeAttributes["environment"] as? String, "PRODUCTION")

        let customBody = AppStoreConnectService.customOfferCodeCreateBody(
            offerID: "offer-id",
            customCode: "FAMILY2026",
            numberOfCodes: 250,
            expirationDate: nil,
            calendar: calendar
        )
        let customData = try XCTUnwrap(customBody["data"] as? [String: Any])
        let customAttributes = try XCTUnwrap(customData["attributes"] as? [String: Any])
        XCTAssertEqual(customAttributes["customCode"] as? String, "FAMILY2026")
        XCTAssertEqual(customAttributes["numberOfCodes"] as? Int, 250)
        XCTAssertNil(customAttributes["expirationDate"])
    }

    func testSubscriptionCreateBodyUsesCurrentAppStoreConnectShape() throws {
        let definition = AppStoreSubscriptionDefinition(
            referenceName: "Premium Annual",
            productID: "com.example.app.premium.yearly",
            period: "ONE_YEAR",
            basePrice: "89.90",
            baseTerritory: "ISR",
            availableInAllTerritories: true,
            familySharable: true,
            groupLevel: 1,
            reviewNote: "Premium access",
            reviewScreenshot: nil,
            localizations: nil
        )
        let body = AppStoreConnectService.subscriptionCreateBody(definition, groupID: "group-id")
        let data = try XCTUnwrap(body["data"] as? [String: Any])
        let attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        let relationships = try XCTUnwrap(data["relationships"] as? [String: Any])
        let group = try XCTUnwrap(relationships["group"] as? [String: Any])
        let linkage = try XCTUnwrap(group["data"] as? [String: Any])

        XCTAssertEqual(data["type"] as? String, "subscriptions")
        XCTAssertEqual(attributes["productId"] as? String, definition.productID)
        XCTAssertEqual(attributes["subscriptionPeriod"] as? String, "ONE_YEAR")
        XCTAssertEqual(attributes["familySharable"] as? Bool, true)
        XCTAssertEqual(linkage["type"] as? String, "subscriptionGroups")
        XCTAssertEqual(linkage["id"] as? String, "group-id")
    }

    func testSourceDiscoveryRequiresSubscriptionProductContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionSourceDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"let subscriptionProductIDs = ["com.example.app.premium.monthly"]"#.write(
            to: root.appendingPathComponent("Purchases.swift"),
            atomically: true,
            encoding: .utf8
        )
        try #"let bundleIdentifier = "com.example.premium.application""#.write(
            to: root.appendingPathComponent("Identity.swift"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = try StoreKitSubscriptionDiscoveryService().discover(
            project: managedProject(at: root),
            defaultLocale: "en-US"
        )
        XCTAssertTrue(catalog.detectedProductIDs.contains("com.example.app.premium.monthly"))
        XCTAssertFalse(catalog.detectedProductIDs.contains("com.example.premium.application"))
        XCTAssertEqual(catalog.subscriptionCount, 1)
        XCTAssertTrue(catalog.sourceFiles.contains("Purchases.swift"))
    }

    func testDiscoversNestedPublishingManifestFromTheAppFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NestedPublishingManifestTests-\(UUID().uuidString)", isDirectory: true)
        let configurationDirectory = root.appendingPathComponent("Config/AppStore", isDirectory: true)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"schemaVersion":1,"publication":{"locale":"fr-FR"}}"#.write(
            to: configurationDirectory.appendingPathComponent("app-store-publishing.json"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = try StoreKitSubscriptionDiscoveryService().discover(
            project: managedProject(at: root),
            defaultLocale: "en-US"
        )
        XCTAssertEqual(catalog.publication?.locale, "fr-FR")
        XCTAssertTrue(catalog.sourceFiles.contains("Config/AppStore/app-store-publishing.json"))
    }

    func testPublishedOlderVersionSelectsVersionOnlyUpdate() {
        let versions: [[String: Any]] = [
            ["attributes": ["versionString": "1.0", "appStoreState": "READY_FOR_SALE"]],
            ["attributes": ["versionString": "1.1", "appStoreState": "PREPARE_FOR_SUBMISSION"]]
        ]
        XCTAssertTrue(
            AppStoreConnectService.isVersionOnlyUpdate(
                versions: versions,
                currentVersion: "1.1"
            )
        )
        XCTAssertFalse(
            AppStoreConnectService.isVersionOnlyUpdate(
                versions: Array(versions.suffix(1)),
                currentVersion: "1.1"
            )
        )
    }

    func testCurrentConfigurationPrefersTheLocalVersionEvenWhenAnotherIsInReview() throws {
        let versions: [[String: Any]] = [
            [
                "id": "older-review",
                "attributes": [
                    "versionString": "1.1",
                    "appStoreState": "IN_REVIEW",
                    "createdDate": "2026-08-16T08:00:00Z"
                ]
            ],
            [
                "id": "local-version",
                "attributes": [
                    "versionString": "1.2",
                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                    "createdDate": "2026-08-15T08:00:00Z"
                ]
            ]
        ]
        let selected = try XCTUnwrap(
            AppStoreConnectService.selectedAppStoreVersion(
                versions,
                preferredVersion: "1.2"
            )
        )
        XCTAssertEqual(selected["id"] as? String, "local-version")
    }

    private func decodedJWTComponent(_ component: String) throws -> [String: Any] {
        var base64 = component.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func managedProject(at root: URL) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: root.path,
            containerPath: root.appendingPathComponent("Example.xcodeproj").path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug", "Release"],
            installMethod: .xcodebuild,
            installScriptPath: nil,
            isEnabled: true,
            marketingVersion: "1.0",
            buildNumber: "1",
            bundleIdentifier: "com.example.app"
        )
    }
}
