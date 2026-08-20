import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import DevManagement

final class AppStorePublishingTests: XCTestCase {
    func testPublishingLogWindowStartsAtPreferredSizeOrFitsShorterScreens() {
        XCTAssertEqual(
            PublishingLogWindowSizing.preferredContentSize,
            NSSize(width: 1_100, height: 790)
        )
        XCTAssertEqual(
            PublishingLogWindowSizing.initialContentHeight(availableScreenHeight: 1_200),
            790
        )
        XCTAssertEqual(
            PublishingLogWindowSizing.initialContentHeight(availableScreenHeight: 850),
            750
        )
    }

    func testPublishingLogWindowRepairsUnreadablyNarrowContentSize() {
        XCTAssertEqual(
            PublishingLogWindowSizing.correctedContentSize(
                for: NSSize(width: 344, height: 1_024)
            ),
            NSSize(width: 720, height: 1_024)
        )
        XCTAssertNil(PublishingLogWindowSizing.correctedContentSize(
            for: NSSize(width: 980, height: 720)
        ))
    }

    func testTestFlightUploadDoesNotRequireStorefrontURLsToBeReachable() {
        XCTAssertFalse(AppStorePublishingService.requiresReachablePublicationURLs(for: .testFlight))
        XCTAssertTrue(AppStorePublishingService.requiresReachablePublicationURLs(for: .publish))
    }

    func testUploadFailureDetectorStopsRepeatedChecksumLoopAcrossOutputChunks() {
        let detector = AppStoreUploadFailureDetector(checksumFailureLimit: 3)

        XCTAssertFalse(detector.observe("WILL RETRY PART 1. Check"))
        XCTAssertFalse(detector.observe("sums do not match.\nChecksums do not match.\n"))
        XCTAssertTrue(detector.observe("Checksums do not match.\n"))
        XCTAssertTrue(detector.didDetectRepeatedChecksumFailures)
    }

    func testUploadFailureDetectorClassifiesOnlyTransientTransferFailures() {
        XCTAssertTrue(AppStoreUploadFailureDetector.isTransientFailure(
            "Error Domain=NSURLErrorDomain Code=-1005 The network connection was lost."
        ))
        XCTAssertTrue(AppStoreUploadFailureDetector.isTransientFailure(
            "WILL RETRY PART 1. Checksums do not match."
        ))
        XCTAssertFalse(AppStoreUploadFailureDetector.isTransientFailure(
            "Authentication credentials are missing or invalid."
        ))
    }

    func testPublicationURLValidatorRetriesRejectedHEADWithFullGET() async throws {
        let session = publicationURLTestSession { request in
            let statusCode = request.httpMethod == "HEAD" ? 405 : 200
            return HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        }
        defer {
            session.invalidateAndCancel()
            PublicationURLProtocolStub.reset()
        }

        try await AppStorePublicationURLValidator(session: session).validate([
            AppStorePublicationURL(
                label: "support",
                url: try XCTUnwrap(URL(string: "https://example.com/support"))
            )
        ])

        XCTAssertEqual(PublicationURLProtocolStub.requestMethods, ["HEAD", "GET"])
        XCTAssertNil(PublicationURLProtocolStub.requests.last?.value(
            forHTTPHeaderField: "Range"
        ))
    }

    func testPublicationURLValidatorExplainsHowToFixHTTPFailure() async throws {
        let session = publicationURLTestSession { request in
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
        }
        defer {
            session.invalidateAndCancel()
            PublicationURLProtocolStub.reset()
        }
        let url = try XCTUnwrap(URL(string: "https://example.com/missing-support"))

        do {
            try await AppStorePublicationURLValidator(session: session).validate([
                AppStorePublicationURL(label: "support", url: url)
            ])
            XCTFail("Expected a public URL validation failure")
        } catch let error as AppStorePublicationURLValidationError {
            guard case .httpFailure(let label, let failedURL, let statusCode) = error else {
                return XCTFail("Unexpected URL validation error: \(error)")
            }
            XCTAssertEqual(label, "support")
            XCTAssertEqual(failedURL, url)
            XCTAssertEqual(statusCode, 404)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 404"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 200–399"))
        }
        XCTAssertEqual(PublicationURLProtocolStub.requestMethods, ["HEAD", "GET"])
    }

    func testPublishingWindowLayoutExpandsAcrossTheAvailableWidth() {
        XCTAssertEqual(PublishingWindowLayout(width: 899), .singleColumn)
        XCTAssertEqual(PublishingWindowLayout(width: 900), .twoColumns)
        XCTAssertEqual(PublishingWindowLayout(width: 1_499), .twoColumns)
        XCTAssertEqual(PublishingWindowLayout(width: 1_500), .threeColumns)
    }

    func testAdditionalLocalizationAccordionStartsOpenOnlyForCompactLists() {
        XCTAssertNil(PublishingLocalizationAccordionPolicy.initialExpandedIndex(itemCount: 0))
        XCTAssertEqual(PublishingLocalizationAccordionPolicy.initialExpandedIndex(itemCount: 1), 0)
        XCTAssertEqual(PublishingLocalizationAccordionPolicy.initialExpandedIndex(itemCount: 5), 0)
        XCTAssertNil(PublishingLocalizationAccordionPolicy.initialExpandedIndex(itemCount: 6))
    }

    func testAdditionalLocalizationAccordionKeepsOneValidExpansionAfterRemoval() {
        XCTAssertEqual(
            PublishingLocalizationAccordionPolicy.expandedIndex(
                afterRemoving: 1,
                currentExpandedIndex: 3,
                remainingItemCount: 4
            ),
            2
        )
        XCTAssertEqual(
            PublishingLocalizationAccordionPolicy.expandedIndex(
                afterRemoving: 2,
                currentExpandedIndex: 2,
                remainingItemCount: 2
            ),
            1
        )
        XCTAssertNil(
            PublishingLocalizationAccordionPolicy.expandedIndex(
                afterRemoving: 0,
                currentExpandedIndex: 0,
                remainingItemCount: 0
            )
        )
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

    func testOpenAIReleaseNotesRequestUsesStrictLocalizedStructuredOutput() throws {
        let body = OpenAIStoreMetadataService.releaseNotesRequestBody(
            model: "gpt-5.6-luna",
            prompt: "Changes after 1.0",
            locales: ["en-US", "he"]
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let localizations = try XCTUnwrap(properties["localizations"] as? [String: Any])
        XCTAssertEqual(localizations["minItems"] as? Int, 2)
        XCTAssertEqual(localizations["maxItems"] as? Int, 2)
        let items = try XCTUnwrap(localizations["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let locale = try XCTUnwrap(itemProperties["locale"] as? [String: Any])
        XCTAssertEqual(locale["enum"] as? [String], ["en-US", "he"])
        XCTAssertNotNil(itemProperties["whatsNew"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testREADMEReleaseEvidencePrefersCurrentVersionSection() {
        let readme = """
        # Example

        ## 2.0.0
        - Adds offline route viewing.
        - Makes shared trips easier to update.

        ## 1.9.0
        - Older change.
        """

        let section = AppStoreReleaseNotesEvidenceService.releaseSection(
            in: readme,
            currentVersion: "2.0.0"
        )

        XCTAssertTrue(section?.contains("offline route viewing") == true)
        XCTAssertFalse(section?.contains("Older change") == true)
    }

    func testReleaseEvidenceFallsBackToGitChangesAfterApprovedTag() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        try await runner.runAndRequireSuccess(executable: git, arguments: ["init"], workingDirectory: root)
        try "# Example\n\nA travel app.\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "MARKETING_VERSION = 1.0.0\n".write(
            to: root.appendingPathComponent("Version.xcconfig"),
            atomically: true,
            encoding: .utf8
        )
        try await runner.runAndRequireSuccess(executable: git, arguments: ["add", "."], workingDirectory: root)
        try await runner.runAndRequireSuccess(
            executable: git,
            arguments: [
                "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
                "commit", "-m", "Release 1.0.0"
            ],
            workingDirectory: root
        )
        try await runner.runAndRequireSuccess(
            executable: git,
            arguments: ["tag", "v1.0.0"],
            workingDirectory: root
        )
        try "struct OfflineRoutes {}\n".write(
            to: root.appendingPathComponent("OfflineRoutes.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await runner.runAndRequireSuccess(executable: git, arguments: ["add", "."], workingDirectory: root)
        try await runner.runAndRequireSuccess(
            executable: git,
            arguments: [
                "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
                "commit", "-m", "Add offline routes"
            ],
            workingDirectory: root
        )

        let evidence = await AppStoreReleaseNotesEvidenceService().evidence(
            project: managedProject(at: root),
            previousVersion: "1.0.0",
            currentVersion: "2.0.0"
        )

        XCTAssertEqual(evidence?.source, .git)
        XCTAssertTrue(evidence?.sourceDescription.contains("v1.0.0") == true)
        XCTAssertTrue(evidence?.content.contains("Add offline routes") == true)
        XCTAssertFalse(evidence?.content.contains("Release 1.0.0") == true)
    }

    func testOpenAIComplianceRequestUsesStrictEnumsAndDoesNotStoreProjectData() throws {
        let body = OpenAIStoreMetadataService.complianceRequestBody(
            model: "gpt-5.6-luna",
            prompt: "README excerpt"
        )
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let rights = try XCTUnwrap(properties["contentRightsDeclaration"] as? [String: Any])
        XCTAssertEqual(
            rights["enum"] as? [String],
            ["DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"]
        )
        XCTAssertNotNil(properties["ageRating"])
        XCTAssertNotNil(properties["ageRatingEvidenceSufficient"])
        XCTAssertNotNil(properties["privacy"])
        XCTAssertNotNil(properties["privacyEvidenceSufficient"])
        XCTAssertNotNil(properties["copyright"])

        let ageRating = try XCTUnwrap(properties["ageRating"] as? [String: Any])
        let ageRatingProperties = try XCTUnwrap(ageRating["properties"] as? [String: Any])
        let requiredAgeRatingFields = try XCTUnwrap(ageRating["required"] as? [String])
        XCTAssertEqual(ageRatingProperties.count, 24)
        XCTAssertEqual(Set(requiredAgeRatingFields), Set(ageRatingProperties.keys))
        XCTAssertNotNil(ageRatingProperties["advertising"])
        XCTAssertNotNil(ageRatingProperties["messagingAndChat"])
        XCTAssertNotNil(ageRatingProperties["medicalOrTreatmentInformation"])
        XCTAssertNotNil(ageRatingProperties["violenceRealistic"])

        var explicitAgeRatingAnswers: [String: AppStoreManifestValue] = [:]
        for (key, value) in ageRatingProperties {
            let field = try XCTUnwrap(value as? [String: Any])
            explicitAgeRatingAnswers[key] = field["type"] as? String == "boolean"
                ? .bool(false)
                : .string("NONE")
        }
        XCTAssertTrue(AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(explicitAgeRatingAnswers))
        explicitAgeRatingAnswers.removeValue(forKey: "advertising")
        XCTAssertFalse(AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(explicitAgeRatingAnswers))

        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("ageRatingEvidenceSufficient"))
        XCTAssertTrue(required.contains("privacyEvidenceSufficient"))
    }

    func testOpenAIComplianceDefaultsUnknownAgeRatingsToNoButKeepsPrivacyEvidenceBased() {
        let unsupported = AppStoreComplianceDraft(
            contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
            appIsFree: true,
            demoAccountRequired: false,
            copyright: "",
            ageRating: ["advertising": .bool(false)],
            ageRatingEvidenceSufficient: false,
            privacy: AppStorePrivacyDraft(collectsData: false, dataTypes: [], notes: []),
            privacyEvidenceSufficient: false,
            evidence: [],
            confidence: 0.2
        )
        let completedAgeRating = unsupported.ageRatingDefaultingUnknownToNo
        XCTAssertTrue(AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(completedAgeRating))
        XCTAssertEqual(completedAgeRating["advertising"], .bool(false))
        XCTAssertEqual(completedAgeRating["violenceRealistic"], .string("NONE"))
        XCTAssertNil(unsupported.evidenceBackedPrivacy)

        var supported = unsupported
        supported.ageRatingEvidenceSufficient = true
        supported.privacyEvidenceSufficient = true
        XCTAssertEqual(supported.ageRatingDefaultingUnknownToNo, completedAgeRating)
        XCTAssertEqual(supported.evidenceBackedPrivacy, unsupported.privacy)
    }

    func testCopyrightAutomaticallyIncludesYearExactlyOnce() {
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        XCTAssertEqual(AppStoreCopyrightNormalizer.normalized("Ziv Tal", referenceDate: date), "2026 Ziv Tal")
        XCTAssertEqual(AppStoreCopyrightNormalizer.normalized("2026 Ziv Tal", referenceDate: date), "2026 Ziv Tal")
    }

    func testPublishingIntentHardSeparatesTestFlightFromReviewSubmission() {
        XCTAssertFalse(PublishingIntent.testFlight.submitsForReview)
        XCTAssertTrue(PublishingIntent.publish.submitsForReview)
    }

    func testOnlyTestFlightPreservesAppInformationLockedByCurrentState() {
        XCTAssertTrue(PublishingIntent.testFlight.preservesLockedAppInformation(forHTTPStatus: 409))
        XCTAssertFalse(PublishingIntent.testFlight.preservesLockedAppInformation(forHTTPStatus: 422))
        XCTAssertFalse(PublishingIntent.publish.preservesLockedAppInformation(forHTTPStatus: 409))
    }

    func testAppNameAvailabilityConflictIsIdentifiedNarrowly() {
        XCTAssertTrue(AppStoreConnectService.isAppNameAvailabilityConflict(
            status: 409,
            message: "The app name you entered is already being used."
        ))
        XCTAssertFalse(AppStoreConnectService.isAppNameAvailabilityConflict(
            status: 409,
            message: "You cannot create a new version of the App in the current state."
        ))
        XCTAssertFalse(AppStoreConnectService.isAppNameAvailabilityConflict(
            status: 422,
            message: "The app name is not available."
        ))
    }

    func testExistingAppNameConflictPreservesNameAndUpdatesOtherInformation() async throws {
        var patchCount = 0
        let service = try appStoreConnectTestService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/appInfos"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [["type": "appInfos", "id": "info-id", "attributes": ["state": "PREPARE_FOR_SUBMISSION"]]]]
                )
            case ("GET", "/v1/appInfos/info-id/appInfoLocalizations"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [[
                        "type": "appInfoLocalizations",
                        "id": "localization-id",
                        "attributes": [
                            "locale": "en-US",
                            "name": "TripFlow Itinerary",
                            "subtitle": "Old subtitle"
                        ]
                    ]]]
                )
            case ("PATCH", "/v1/appInfoLocalizations/localization-id"):
                patchCount += 1
                let body = try Self.requestBodyData(request)
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let data = try XCTUnwrap(root["data"] as? [String: Any])
                let attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
                if patchCount == 1 {
                    XCTAssertEqual(attributes["name"] as? String, "TripFlow")
                    XCTAssertEqual(attributes["subtitle"] as? String, "New subtitle")
                    return try Self.appStoreConnectResponse(
                        for: request,
                        status: 409,
                        json: ["errors": [["detail": "The app name you entered is already being used."]]]
                    )
                }
                XCTAssertNil(attributes["name"])
                XCTAssertEqual(attributes["subtitle"] as? String, "New subtitle")
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": ["type": "appInfoLocalizations", "id": "localization-id"]]
                )
            default:
                XCTFail("Unexpected App Store Connect request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.appStoreConnectResponse(for: request, status: 500, json: [:])
            }
        }
        defer { AppStoreConnectURLProtocolStub.requestHandler = nil }

        let preservation = try await service.configureLocalizedAppInformation(
            appID: "app-id",
            locale: "en-US",
            appName: "TripFlow",
            subtitle: "New subtitle",
            privacyPolicyURL: nil,
            privacyChoicesURL: nil
        )

        XCTAssertEqual(patchCount, 2)
        XCTAssertEqual(preservation, AppStoreLocalizedNamePreservation(
            locale: "en-US",
            requestedName: "TripFlow",
            existingName: "TripFlow Itinerary"
        ))
    }

    func testUnchangedLocalizedAppInformationDoesNotPatch() async throws {
        let service = try appStoreConnectTestService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/appInfos"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [["type": "appInfos", "id": "info-id", "attributes": ["state": "PREPARE_FOR_SUBMISSION"]]]]
                )
            case ("GET", "/v1/appInfos/info-id/appInfoLocalizations"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [[
                        "type": "appInfoLocalizations",
                        "id": "localization-id",
                        "attributes": [
                            "locale": "en-US",
                            "name": "TripFlow Itinerary",
                            "subtitle": "Plan every trip"
                        ]
                    ]]]
                )
            default:
                XCTFail("Unexpected App Store Connect request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.appStoreConnectResponse(for: request, status: 500, json: [:])
            }
        }
        defer { AppStoreConnectURLProtocolStub.requestHandler = nil }

        let preservation = try await service.configureLocalizedAppInformation(
            appID: "app-id",
            locale: "en-US",
            appName: "TripFlow Itinerary",
            subtitle: "Plan every trip",
            privacyPolicyURL: nil,
            privacyChoicesURL: nil
        )

        XCTAssertNil(preservation)
        XCTAssertEqual(AppStoreConnectURLProtocolStub.requests.count, 2)
    }

    func testLockedTestFlightUploadPreservesSubmittedSubscriptionConfiguration() {
        XCTAssertTrue(AppStorePublishingService.preservesExistingSubscriptionConfiguration(
            intent: .testFlight,
            appInformationIsLocked: true
        ))
        XCTAssertFalse(AppStorePublishingService.preservesExistingSubscriptionConfiguration(
            intent: .testFlight,
            appInformationIsLocked: false
        ))
        XCTAssertFalse(AppStorePublishingService.preservesExistingSubscriptionConfiguration(
            intent: .publish,
            appInformationIsLocked: true
        ))
    }

    func testAppStoreConnectRetriesSafeRequestsAfterTransientServerFailure() async throws {
        let service = try appStoreConnectTestService { request in
            if AppStoreConnectURLProtocolStub.requests.count == 1 {
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 500,
                    json: ["errors": [["detail": "Temporary server failure"]]],
                    headers: ["Retry-After": "0"]
                )
            }
            return try Self.appStoreConnectResponse(
                for: request,
                status: 200,
                json: ["data": [["type": "apps", "id": "app-id"]]]
            )
        }
        defer { AppStoreConnectURLProtocolStub.requestHandler = nil }

        let response = try await service.request(method: "GET", path: "/v1/apps")

        XCTAssertEqual((response["data"] as? [[String: Any]])?.first?["id"] as? String, "app-id")
        XCTAssertEqual(AppStoreConnectURLProtocolStub.requests.count, 2)
        XCTAssertTrue(AppStoreConnectService.shouldRetryRequest(
            method: "PATCH",
            statusCode: 503,
            retryCount: 0
        ))
        XCTAssertFalse(AppStoreConnectService.shouldRetryRequest(
            method: "POST",
            statusCode: 500,
            retryCount: 0
        ))
    }

    func testTestFlightDefersStorefrontSetupWhenAnotherVersionIsInReview() async throws {
        let service = try appStoreConnectTestService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [["type": "apps", "id": "app-id"]]]
                )
            case ("GET", "/v1/apps/app-id/appStoreVersions"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: [
                        "data": [[
                            "type": "appStoreVersions",
                            "id": "version-in-review",
                            "attributes": [
                                "versionString": "2.1.7",
                                "appStoreState": "WAITING_FOR_REVIEW"
                            ]
                        ]]
                    ]
                )
            case ("POST", "/v1/appStoreVersions"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 409,
                    json: ["errors": [["detail": "You cannot create a new version of the App in the current state."]]]
                )
            default:
                XCTFail("Unexpected App Store Connect request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.appStoreConnectResponse(for: request, status: 500, json: [:])
            }
        }
        defer { AppStoreConnectURLProtocolStub.requestHandler = nil }

        let publication = try await preparePublication(service: service, intent: .testFlight)

        XCTAssertTrue(publication.deferredStorefrontSetup)
        XCTAssertTrue(publication.preservedLockedAppInformation)
        XCTAssertNil(publication.versionID)
        XCTAssertNil(publication.localizationID)
        XCTAssertTrue(publication.localizationIDsByLocale.isEmpty)
        XCTAssertEqual(
            AppStoreConnectURLProtocolStub.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /v1/apps",
                "GET /v1/apps/app-id/appStoreVersions",
                "GET /v1/apps/app-id/appStoreVersions",
                "POST /v1/appStoreVersions",
                "GET /v1/apps/app-id/appStoreVersions"
            ]
        )
    }

    func testTestFlightDoesNotIgnoreUnrelatedVersionCreationConflict() async throws {
        let service = try appStoreConnectTestService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": [["type": "apps", "id": "app-id"]]]
                )
            case ("GET", "/v1/apps/app-id/appStoreVersions"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 200,
                    json: ["data": []]
                )
            case ("POST", "/v1/appStoreVersions"):
                return try Self.appStoreConnectResponse(
                    for: request,
                    status: 409,
                    json: ["errors": [["detail": "Version creation is unavailable."]]]
                )
            default:
                XCTFail("Unexpected App Store Connect request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.appStoreConnectResponse(for: request, status: 500, json: [:])
            }
        }
        defer { AppStoreConnectURLProtocolStub.requestHandler = nil }

        do {
            _ = try await preparePublication(service: service, intent: .testFlight)
            XCTFail("Expected the App Store version creation conflict to be preserved")
        } catch AppStoreConnectError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "Version creation is unavailable.")
        }
    }

    func testStorefrontBlockingStatesMatchAppleReviewAndReleaseLifecycle() {
        XCTAssertTrue(AppStoreConnectService.hasVersionBlockingNewStorefront(in: [[
            "attributes": ["appStoreState": "WAITING_FOR_REVIEW"]
        ]]))
        XCTAssertTrue(AppStoreConnectService.hasVersionBlockingNewStorefront(in: [[
            "attributes": ["appStoreState": "PENDING_DEVELOPER_RELEASE"]
        ]]))
        XCTAssertTrue(AppStoreConnectService.hasVersionBlockingNewStorefront(in: [[
            "attributes": ["appStoreState": "PROCESSING_FOR_DISTRIBUTION"]
        ]]))
        XCTAssertFalse(AppStoreConnectService.hasVersionBlockingNewStorefront(in: [[
            "attributes": ["appStoreState": "READY_FOR_DISTRIBUTION"]
        ]]))
        XCTAssertFalse(AppStoreConnectService.hasVersionBlockingNewStorefront(in: [[
            "attributes": ["appStoreState": "PREPARE_FOR_SUBMISSION"]
        ]]))
    }

    func testCurrentAppInfoPrefersEditableDraftOverLockedLiveInformation() throws {
        let live: [String: Any] = [
            "id": "live-info",
            "attributes": ["state": "READY_FOR_DISTRIBUTION"]
        ]
        let rejected: [String: Any] = [
            "id": "rejected-info",
            "attributes": ["appStoreState": "DEVELOPER_REJECTED"]
        ]
        let draft: [String: Any] = [
            "id": "draft-info",
            "attributes": ["state": "PREPARE_FOR_SUBMISSION"]
        ]

        let selected = try XCTUnwrap(AppStoreConnectService.currentAppInfo([
            live,
            rejected,
            draft
        ]))

        XCTAssertEqual(selected["id"] as? String, "draft-info")
    }

    func testSubscriptionFieldEditorRoundTripsEveryPublishableValue() throws {
        let definition = AppStoreSubscriptionDefinition(
            referenceName: "Premium Annual",
            productID: "com.example.premium.annual",
            period: "ONE_YEAR",
            basePrice: "69.90",
            baseTerritory: "USA",
            territoryPrices: ["ISR": "199.90"],
            availableInAllTerritories: true,
            familySharable: true,
            groupLevel: 1,
            reviewNote: "Full premium access.",
            reviewScreenshot: "Screenshots/paywall.png",
            localizations: [
                AppStoreSubscriptionLocalization(
                    locale: "en-US",
                    name: "Premium Annual",
                    description: "Annual premium access."
                )
            ]
        )

        var form = PublishingSubscriptionProductForm(definition)
        form.territoryPrices.append(PublishingTerritoryPriceForm(territory: "isr", price: "209.90"))
        let saved = form.definition

        XCTAssertEqual(saved.referenceName, definition.referenceName)
        XCTAssertEqual(saved.productID, definition.productID)
        XCTAssertEqual(saved.period, "ONE_YEAR")
        XCTAssertEqual(saved.basePrice, "69.90")
        XCTAssertEqual(saved.baseTerritory, "USA")
        XCTAssertEqual(saved.territoryPrices, ["ISR": "209.90"])
        XCTAssertEqual(saved.availableInAllTerritories, true)
        XCTAssertEqual(saved.familySharable, true)
        XCTAssertEqual(saved.groupLevel, 1)
        XCTAssertEqual(saved.reviewNote, "Full premium access.")
        XCTAssertEqual(saved.reviewScreenshot, "Screenshots/paywall.png")
        XCTAssertEqual(saved.localizations?.first?.locale, "en-US")
        XCTAssertEqual(saved.localizations?.first?.name, "Premium Annual")
    }

    func testSubscriptionFieldEditorCanonicalizesImportedAppStoreLocale() {
        let form = PublishingSubscriptionLocalizationForm(
            AppStoreSubscriptionLocalization(
                locale: "he-IL",
                name: "פרימיום",
                description: nil
            )
        )

        XCTAssertEqual(form.definition.locale, "he")
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

    func testOpenAIResponseDecodesAndAppliesLocalizedReleaseNotes() throws {
        let generated = AppStoreGeneratedReleaseNotes(localizations: [
            AppStoreGeneratedReleaseNotesLocalization(
                locale: "en-US",
                whatsNew: "View routes offline."
            ),
            AppStoreGeneratedReleaseNotesLocalization(
                locale: "he",
                whatsNew: "צפייה במסלולים ללא חיבור."
            )
        ])
        let generatedData = try JSONEncoder().encode(generated)
        let generatedJSON = try XCTUnwrap(String(data: generatedData, encoding: .utf8))
        let responseData = try JSONSerialization.data(
            withJSONObject: ["output_text": generatedJSON]
        )
        let decoded = try OpenAIStoreMetadataService.decodeReleaseNotes(from: responseData)
        let listings = [
            AppStoreLocalizedMetadata(
                locale: "en",
                appName: "Example",
                subtitle: "Plan trips",
                description: "Description",
                keywords: "travel",
                promotionalText: "Plan now.",
                whatsNew: "Old English notes"
            ),
            AppStoreLocalizedMetadata(
                locale: "he",
                appName: "Example",
                subtitle: "תכנון טיולים",
                description: "תיאור",
                keywords: "טיולים",
                promotionalText: "תכננו עכשיו.",
                whatsNew: "הערות ישנות"
            )
        ]

        let updated = AppStorePublishingService.applyingReleaseNotes(decoded, to: listings)

        XCTAssertEqual(updated.map(\.whatsNew), [
            "View routes offline.",
            "צפייה במסלולים ללא חיבור."
        ])
        XCTAssertEqual(updated.map(\.appName), ["Example", "Example"])
        XCTAssertEqual(updated.map(\.subtitle), ["Plan trips", "תכנון טיולים"])
        XCTAssertEqual(updated.map(\.description), ["Description", "תיאור"])
        XCTAssertEqual(updated.map(\.keywords), ["travel", "טיולים"])
        XCTAssertEqual(updated.map(\.promotionalText), ["Plan now.", "תכננו עכשיו."])
    }

    func testMissingApprovedVersionExplainsWhyWhatsNewCannotBeGenerated() {
        XCTAssertEqual(
            OpenAIStoreMetadataError.missingApprovedVersion.errorDescription,
            L10n.text("App Store Connect has no earlier approved version to use as the What’s New baseline.")
        )
    }

    func testLocalizedOpenAIResponseRequiresAndDecodesAppAnswers() throws {
        let generated = AppStoreGeneratedMetadata(
            primaryCategory: "FINANCE",
            secondaryCategory: "",
            localizations: [
                AppStoreLocalizedMetadata(
                    locale: "en-US",
                    appName: "Example",
                    subtitle: "Useful example",
                    description: "A useful application.",
                    keywords: "useful,application",
                    promotionalText: "Try it today.",
                    whatsNew: "Performance improvements."
                )
            ],
            compliance: AppStoreComplianceDraft(
                contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
                appIsFree: true,
                demoAccountRequired: false,
                copyright: "2026 Example",
                ageRating: ["advertising": .bool(false)],
                ageRatingEvidenceSufficient: true,
                privacy: AppStorePrivacyDraft(
                    collectsData: false,
                    dataTypes: [],
                    notes: ["No collection path is present."]
                ),
                privacyEvidenceSufficient: true,
                evidence: ["Sources/App.swift — local storage only"],
                confidence: 0.9
            )
        )
        let generatedData = try JSONEncoder().encode(generated)
        let generatedJSON = try XCTUnwrap(String(data: generatedData, encoding: .utf8))
        let responseData = try JSONSerialization.data(withJSONObject: ["output_text": generatedJSON])

        let decoded = try OpenAIStoreMetadataService.decodeLocalizedMetadata(from: responseData)

        XCTAssertEqual(decoded, generated)
        XCTAssertEqual(decoded.compliance.ageRating["advertising"], .bool(false))
        XCTAssertEqual(decoded.compliance.evidenceBackedPrivacy, generated.compliance.privacy)

        let missingComplianceJSON = """
        {"primaryCategory":"FINANCE","secondaryCategory":"","localizations":[]}
        """
        let missingComplianceResponse = try JSONSerialization.data(
            withJSONObject: ["output_text": missingComplianceJSON]
        )
        XCTAssertThrowsError(
            try OpenAIStoreMetadataService.decodeLocalizedMetadata(from: missingComplianceResponse)
        )
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
        XCTAssertNil(properties["supportURL"])
        XCTAssertNil(properties["marketingURL"])
        XCTAssertNil(properties["privacyPolicyURL"])
        XCTAssertNil(properties["termsURL"])
        XCTAssertNil(properties["contentRightsDeclaration"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("primaryCategory"))
    }

    func testOpenAIGenerationPolicyKeepsURLsManualAndRequiresVerifiedThirdPartyFacts() {
        let policy = OpenAIStoreMetadataService.generationPolicy

        XCTAssertTrue(policy.contains("third-party services"))
        XCTAssertTrue(policy.contains("explicitly verified"))
        XCTAssertTrue(policy.contains("URLs are manual publishing fields"))
        XCTAssertTrue(policy.contains("Never generate, guess, replace, or return those URLs"))
    }

    func testOpenAIProjectSummaryIncludesCompleteFirstPartySourceAndDependencyEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAIProjectSummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Trip README".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Travel; Google Maps is optional; no sign-in required.".write(
            to: root.appendingPathComponent("TripSubmissionAndAutomation.md"),
            atomically: true,
            encoding: .utf8
        )
        let packageDirectory = root
            .appendingPathComponent("Example.xcodeproj", isDirectory: true)
            .appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try #"{"pins":[{"identity":"googlemaps"}]}"#.write(
            to: packageDirectory.appendingPathComponent("Package.resolved"),
            atomically: true,
            encoding: .utf8
        )
        let sourceDirectory = root.appendingPathComponent("Sources/Features", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = """
        import CoreLocation
        final class TripLocationService {
            let manager = CLLocationManager()
            func uploadLocation() async { /* network implementation */ }
        }
        """
        try source.write(
            to: sourceDirectory.appendingPathComponent("TripLocationService.swift"),
            atomically: true,
            encoding: .utf8
        )
        let longSource = String(repeating: "// implementation\n", count: 900)
            + "let marker = \"SOURCE_END_MARKER\"\n"
        try longSource.write(
            to: sourceDirectory.appendingPathComponent("CompleteFeature.swift"),
            atomically: true,
            encoding: .utf8
        )
        let vendorDirectory = root.appendingPathComponent("node_modules/vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
        try "SHOULD_NOT_UPLOAD_VENDOR".write(
            to: vendorDirectory.appendingPathComponent("vendor.js"),
            atomically: true,
            encoding: .utf8
        )
        try "API_TOKEN=SHOULD_NOT_UPLOAD_SECRET".write(
            to: root.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let summary = OpenAIStoreMetadataService().projectSummary(for: managedProject(at: root))

        XCTAssertTrue(summary.contains("Complete supported-text snapshot: yes"))
        XCTAssertTrue(summary.contains("--- README.md ---"))
        XCTAssertTrue(summary.contains("--- TripSubmissionAndAutomation.md ---"))
        XCTAssertTrue(summary.contains("Google Maps is optional"))
        XCTAssertTrue(summary.contains("Package.resolved"))
        XCTAssertTrue(summary.contains("googlemaps"))
        XCTAssertTrue(summary.contains("--- Sources/Features/TripLocationService.swift ---"))
        XCTAssertTrue(summary.contains("CLLocationManager"))
        XCTAssertTrue(summary.contains("SOURCE_END_MARKER"))
        XCTAssertFalse(summary.contains("SHOULD_NOT_UPLOAD_VENDOR"))
        XCTAssertFalse(summary.contains("SHOULD_NOT_UPLOAD_SECRET"))
    }

    func testListingDescriptionAppendsManualPrivacyAndTermsLinksWithinLimit() {
        let privacyURL = "https://example.com/privacy"
        let termsURL = "https://example.com/terms"
        let description = AppStoreConnectService.listingDescription(
            String(repeating: "A", count: 4_000),
            locale: "en-US",
            privacyPolicyURL: privacyURL,
            termsURL: termsURL
        )

        XCTAssertEqual(description.count, 4_000)
        XCTAssertTrue(description.contains("Privacy Policy: \(privacyURL)"))
        XCTAssertTrue(description.contains("Terms of Use: \(termsURL)"))
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
        knownRegions = (Base, en, English, de, NotALocale);
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

    func testPublishingCanonicalizesLocaleNamesAndDropsDuplicatesBeforeAppStoreRequests() {
        func localization(locale: String, description: String) -> AppStoreLocalizedMetadata {
            AppStoreLocalizedMetadata(
                locale: locale,
                appName: "Example",
                subtitle: "Example subtitle",
                description: description,
                keywords: "example",
                promotionalText: "Try it.",
                whatsNew: "Improvements."
            )
        }

        let localizations = AppStorePublishingService.normalizedLocalizedMetadata([
            localization(locale: "en-US", description: "Primary English listing"),
            localization(locale: "English", description: "Duplicate English listing"),
            localization(locale: "he_IL", description: "Hebrew listing"),
            localization(locale: "NotALocale", description: "Unsupported listing")
        ])

        XCTAssertEqual(localizations.map(\.locale), ["en-US", "he"])
        XCTAssertEqual(localizations.first?.description, "Primary English listing")
        XCTAssertFalse(localizations.contains { $0.locale == "English" })
    }

    func testSubscriptionLocalizationsUseSupportedAppStoreLocaleCodes() {
        let localizations = AppStoreConnectService.normalizedSubscriptionLocalizations([
            AppStoreSubscriptionLocalization(
                locale: "he-IL",
                name: "פרימיום",
                description: "גישה לכל התכונות."
            ),
            AppStoreSubscriptionLocalization(
                locale: "Hebrew",
                name: "Duplicate Hebrew",
                description: nil
            ),
            AppStoreSubscriptionLocalization(
                locale: "en_US",
                name: "Premium",
                description: "Access to every feature."
            ),
            AppStoreSubscriptionLocalization(
                locale: "NotALocale",
                name: "Unsupported",
                description: nil
            )
        ])

        XCTAssertEqual(localizations.map(\.locale), ["he", "en-US"])
        XCTAssertEqual(localizations.first?.name, "פרימיום")
        XCTAssertFalse(localizations.contains { $0.name == "Unsupported" })
    }

    func testSubscriptionLocalizationUpdatesOmitImmutableLocaleAttribute() {
        let localization = AppStoreSubscriptionLocalization(
            locale: "he",
            name: "פרימיום",
            description: "גישה לכל התכונות."
        )

        let groupCreate = AppStoreConnectService.subscriptionGroupLocalizationAttributes(
            localization,
            includesLocale: true
        )
        let groupUpdate = AppStoreConnectService.subscriptionGroupLocalizationAttributes(
            localization,
            includesLocale: false
        )
        XCTAssertEqual(groupCreate["locale"] as? String, "he")
        XCTAssertNil(groupUpdate["locale"])
        XCTAssertEqual(groupUpdate["name"] as? String, "פרימיום")
        XCTAssertEqual(groupUpdate["customAppName"] as? String, "גישה לכל התכונות.")

        let productCreate = AppStoreConnectService.subscriptionLocalizationAttributes(
            localization,
            includesLocale: true
        )
        let productUpdate = AppStoreConnectService.subscriptionLocalizationAttributes(
            localization,
            includesLocale: false
        )
        XCTAssertEqual(productCreate["locale"] as? String, "he")
        XCTAssertNil(productUpdate["locale"])
        XCTAssertEqual(productUpdate["name"] as? String, "פרימיום")
        XCTAssertEqual(productUpdate["description"] as? String, "גישה לכל התכונות.")
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
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(
                width: 422,
                height: 514,
                platform: .appleWatch
            ),
            "APP_WATCH_ULTRA"
        )
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(
                width: 1_920,
                height: 1_080,
                platform: .appleTV
            ),
            "APP_APPLE_TV"
        )
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(
                width: 3_840,
                height: 2_160,
                platform: .appleVisionPro
            ),
            "APP_APPLE_VISION_PRO"
        )
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 800, height: 600))
    }

    func testScreenshotLocaleIsInferredFromLocalizedFolder() {
        XCTAssertEqual(
            AppStorePublishingService.screenshotLocale(
                from: URL(fileURLWithPath: "/AppStore/Screenshots/en-US/APP_IPHONE_67/home.png")
            ),
            "en-US"
        )
        XCTAssertEqual(
            AppStorePublishingService.screenshotLocale(
                from: URL(fileURLWithPath: "/AppStore/Screenshots/he/APP_IPHONE_67/home.png")
            ),
            "he"
        )
    }

    func testScreenshotPreparationDetectsCompanionWatchApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotTargetTests-\(UUID().uuidString)", isDirectory: true)
        let watchDirectory = root.appendingPathComponent("ExampleWatch", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "WKApplication": true,
            "WKCompanionAppBundleIdentifier": "com.example.app"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: watchDirectory.appendingPathComponent("Info.plist"))

        var project = managedProject(at: root)
        project.availableSchemes = ["Example", "ExampleWatch"]
        project.supportedDeviceFamilies = [.iPhone, .iPad]

        XCTAssertEqual(
            AppStorePublishingService().supportedScreenshotPlatforms(for: project),
            [.iPhone, .iPad, .appleWatch]
        )
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
        XCTAssertNil(preferences.appStoreReleaseAutomatically)
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
            "familySharable": true,
            "reviewScreenshot": "Screenshots/subscription-review.png",
            "groups": [{
              "referenceName": "Premium",
              "subscriptions": [{
                "referenceName": "Premium Monthly",
                "productID": "com.example.app.premium.monthly",
                "period": "ONE_MONTH",
                "reviewNote": "Keep the discovered StoreKit price."
              }]
            }]
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
        XCTAssertEqual(subscription.familySharable, true)
        XCTAssertEqual(subscription.reviewScreenshot, "Screenshots/subscription-review.png")
        XCTAssertEqual(subscription.reviewNote, "Keep the discovered StoreKit price.")
        XCTAssertEqual(subscription.localizations?.first?.locale, "en-US")
    }

    func testCurrentSubscriptionPriceUsesTheActiveBaseTerritorySchedule() throws {
        let snapshot = AppStoreConnectSubscriptionSnapshot(
            id: "subscription-id",
            referenceName: "Premium Monthly",
            productID: "com.example.monthly",
            state: "READY_FOR_REVIEW",
            period: "ONE_MONTH",
            familySharable: false,
            groupLevel: 1,
            reviewNote: nil,
            localizations: [],
            availableTerritoryIDs: ["USA"],
            availableInNewTerritories: true,
            prices: [
                AppStoreConnectSubscriptionPriceSnapshot(
                    territory: "USA",
                    price: "7.99",
                    currency: "USD",
                    startDate: "2025-01-01",
                    endDate: "2025-12-31",
                    preserved: false
                ),
                AppStoreConnectSubscriptionPriceSnapshot(
                    territory: "USA",
                    price: "9.99",
                    currency: "USD",
                    startDate: "2026-01-01",
                    endDate: nil,
                    preserved: false
                ),
                AppStoreConnectSubscriptionPriceSnapshot(
                    territory: "USA",
                    price: "12.99",
                    currency: "USD",
                    startDate: "2027-01-01",
                    endDate: nil,
                    preserved: false
                )
            ],
            offers: []
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 18
        )))

        XCTAssertEqual(
            snapshot.currentPrice(in: "usa", referenceDate: referenceDate),
            "9.99"
        )
    }

    func testReadyForReviewSubscriptionVersionIsReused() {
        let versions: [[String: Any]] = [
            [
                "id": "approved-version",
                "attributes": ["state": "APPROVED", "version": 1]
            ],
            [
                "id": "inflight-version",
                "attributes": ["state": "READY_FOR_REVIEW", "version": 2]
            ]
        ]

        XCTAssertEqual(
            AppStoreConnectService.reusableSubscriptionVersionID(in: versions),
            "inflight-version"
        )
    }

    func testManifestDecodesTerritoryPricesAndTestFlightAutomation() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "publication": {
            "testFlight": {
              "groupName": "Internal Testing",
              "feedbackEmail": "owner@example.com",
              "internalTesterEmails": ["owner@example.com"]
            }
          },
          "subscriptions": {
            "groups": [{
              "referenceName": "Premium",
              "subscriptions": [{
                "referenceName": "Monthly",
                "productID": "com.example.monthly",
                "period": "ONE_MONTH",
                "basePrice": "13.90",
                "baseTerritory": "USA",
                "territoryPrices": {"ISR": "39.00"}
              }]
            }]
          }
        }
        """#.utf8)
        let manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: data)
        XCTAssertEqual(manifest.publication?.testFlight?.groupName, "Internal Testing")
        XCTAssertEqual(manifest.publication?.testFlight?.internalTesterEmails, ["owner@example.com"])
        XCTAssertEqual(
            manifest.subscriptions?.groups?.first?.subscriptions.first?.territoryPrices?["ISR"],
            "39.00"
        )
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
            subscriptionID: "subscription-id",
            territoryIDs: ["USA", "ISR", "USA"]
        )
        let offerData = try XCTUnwrap(offerBody["data"] as? [String: Any])
        let offerAttributes = try XCTUnwrap(offerData["attributes"] as? [String: Any])
        let offerRelationships = try XCTUnwrap(offerData["relationships"] as? [String: Any])
        let prices = try XCTUnwrap(offerRelationships["prices"] as? [String: Any])
        let priceLinkages = try XCTUnwrap(prices["data"] as? [[String: String]])
        let includedPrices = try XCTUnwrap(offerBody["included"] as? [[String: Any]])
        XCTAssertEqual(offerData["type"] as? String, "subscriptionOfferCodes")
        XCTAssertEqual(offerAttributes["offerMode"] as? String, "FREE_TRIAL")
        XCTAssertEqual(offerAttributes["duration"] as? String, "ONE_MONTH")
        XCTAssertEqual(offerAttributes["customerEligibilities"] as? [String], ["EXPIRED", "NEW"])
        XCTAssertEqual(priceLinkages, [
            ["type": "subscriptionOfferCodePrices", "id": "${offer-price-ISR}"],
            ["type": "subscriptionOfferCodePrices", "id": "${offer-price-USA}"]
        ])
        XCTAssertEqual(includedPrices.count, 2)
        XCTAssertEqual(
            includedPrices.compactMap { $0["id"] as? String },
            ["${offer-price-ISR}", "${offer-price-USA}"]
        )
        XCTAssertTrue(includedPrices.allSatisfy {
            guard let id = $0["id"] as? String else { return false }
            return id.hasPrefix("${") && id.hasSuffix("}")
        })
        let firstIncludedRelationships = try XCTUnwrap(
            includedPrices.first?["relationships"] as? [String: Any]
        )
        let firstTerritory = try XCTUnwrap(
            firstIncludedRelationships["territory"] as? [String: Any]
        )
        XCTAssertEqual(
            firstTerritory["data"] as? [String: String],
            ["type": "territories", "id": "ISR"]
        )

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
        try #"try await purchase("com.example.app.premium.yearly")"#.write(
            to: root.appendingPathComponent("PurchaseCall.swift"),
            atomically: true,
            encoding: .utf8
        )
        try #"""
        switch notice {
        case .purchaseFailed:
            title = "subscription.error.title"
        default:
            break
        }
        """#.write(
            to: root.appendingPathComponent("SubscriptionNotice.swift"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = try StoreKitSubscriptionDiscoveryService().discover(
            project: managedProject(at: root),
            defaultLocale: "en-US"
        )
        XCTAssertTrue(catalog.detectedProductIDs.contains("com.example.app.premium.monthly"))
        XCTAssertTrue(catalog.detectedProductIDs.contains("com.example.app.premium.yearly"))
        XCTAssertFalse(catalog.detectedProductIDs.contains("com.example.premium.application"))
        XCTAssertFalse(catalog.detectedProductIDs.contains("subscription.error.title"))
        XCTAssertEqual(catalog.subscriptionCount, 2)
        XCTAssertTrue(catalog.sourceFiles.contains("Purchases.swift"))
        XCTAssertTrue(catalog.sourceFiles.contains("PurchaseCall.swift"))
        XCTAssertFalse(catalog.sourceFiles.contains("SubscriptionNotice.swift"))
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

    func testSnapshotFindsActiveReviewVersionSeparatelyFromPreferredVersion() throws {
        let versions: [[String: Any]] = [
            [
                "id": "review-version",
                "attributes": [
                    "versionString": "1.9.8",
                    "appStoreState": "WAITING_FOR_REVIEW"
                ]
            ],
            [
                "id": "draft-version",
                "attributes": [
                    "versionString": "1.9.9",
                    "appStoreState": "PREPARE_FOR_SUBMISSION"
                ]
            ]
        ]

        let active = try XCTUnwrap(AppStoreConnectService.activeReviewVersion(in: versions))

        XCTAssertEqual(active.id, "review-version")
        XCTAssertEqual(active.versionString, "1.9.8")
    }

    func testDraftVersionDoesNotTriggerReviewCancellationWarning() {
        let versions: [[String: Any]] = [[
            "id": "draft-version",
            "attributes": [
                "versionString": "1.9.9",
                "appStoreState": "READY_FOR_REVIEW"
            ]
        ]]

        XCTAssertNil(AppStoreConnectService.activeReviewVersion(in: versions))
    }

    func testRedeemCodeAppEligibilityRequiresReadyForDistributionVersion() {
        XCTAssertFalse(AppStoreConnectService.hasReadyForDistributionVersion(in: [
            ["attributes": ["appStoreState": "WAITING_FOR_REVIEW"]]
        ]))
        XCTAssertTrue(AppStoreConnectService.hasReadyForDistributionVersion(in: [
            ["attributes": ["appStoreState": "READY_FOR_DISTRIBUTION"]]
        ]))
        XCTAssertTrue(AppStoreConnectService.hasReadyForDistributionVersion(in: [
            ["attributes": ["appStoreState": "READY_FOR_SALE"]]
        ]))
    }

    func testLatestApprovedVersionChoosesNewestReleasedPredecessor() throws {
        let versions: [[String: Any]] = [
            [
                "id": "old-approved",
                "attributes": [
                    "versionString": "1.9.0",
                    "appStoreState": "REPLACED_WITH_NEW_VERSION"
                ]
            ],
            [
                "id": "latest-approved",
                "attributes": [
                    "versionString": "1.10.0",
                    "appStoreState": "READY_FOR_DISTRIBUTION"
                ]
            ],
            [
                "id": "current-draft",
                "attributes": [
                    "versionString": "1.11.0",
                    "appStoreState": "PREPARE_FOR_SUBMISSION"
                ]
            ]
        ]

        let approved = try XCTUnwrap(AppStoreConnectService.latestApprovedVersion(
            in: versions,
            excluding: "1.11.0"
        ))

        XCTAssertEqual(approved.id, "latest-approved")
        XCTAssertEqual(approved.versionString, "1.10.0")
    }

    func testClosestSubscriptionPricePointChoosesExactThenNearestLowerTie() throws {
        let points: [[String: Any]] = [
            ["id": "lower", "attributes": ["customerPrice": "199.89"]],
            ["id": "upper", "attributes": ["customerPrice": "199.91"]],
            ["id": "apple", "attributes": ["customerPrice": "199.99"]]
        ]

        let exact = try XCTUnwrap(AppStoreConnectService.closestSubscriptionPricePoint(
            in: points,
            requestedPrice: "199.99"
        ))
        XCTAssertEqual(exact.id, "apple")
        XCTAssertEqual(exact.price, "199.99")

        let nearest = try XCTUnwrap(AppStoreConnectService.closestSubscriptionPricePoint(
            in: points,
            requestedPrice: "199.90"
        ))
        XCTAssertEqual(nearest.id, "lower")
        XCTAssertEqual(nearest.price, "199.89")
        XCTAssertNil(AppStoreConnectService.closestSubscriptionPricePoint(
            in: points,
            requestedPrice: "not-a-price"
        ))
    }

    func testReusableDraftVersionChoosesNewestEditableVersion() throws {
        let versions: [[String: Any]] = [
            [
                "id": "released",
                "attributes": [
                    "versionString": "1.8.0",
                    "appStoreState": "READY_FOR_DISTRIBUTION"
                ]
            ],
            [
                "id": "older-draft",
                "attributes": [
                    "versionString": "1.9.0",
                    "appStoreState": "DEVELOPER_REJECTED"
                ]
            ],
            [
                "id": "newer-draft",
                "attributes": [
                    "versionString": "1.9.1",
                    "appStoreState": "PREPARE_FOR_SUBMISSION"
                ]
            ]
        ]

        let draft = try XCTUnwrap(AppStoreConnectService.reusableDraftVersion(in: versions))
        XCTAssertEqual(draft.id, "newer-draft")
        XCTAssertEqual(draft.versionString, "1.9.1")
    }

    func testMatchingTestFlightBuildRequiresExactIOSVersionAndBuild() throws {
        let builds: [[String: Any]] = [
            [
                "id": "wrong-version",
                "attributes": ["version": "43", "processingState": "VALID"],
                "relationships": [
                    "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": "train-1"]]
                ]
            ],
            [
                "id": "matching",
                "attributes": ["version": "43", "processingState": "VALID"],
                "relationships": [
                    "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": "train-2"]]
                ]
            ]
        ]
        let included: [[String: Any]] = [
            [
                "type": "preReleaseVersions",
                "id": "train-1",
                "attributes": ["version": "1.4.1", "platform": "IOS"]
            ],
            [
                "type": "preReleaseVersions",
                "id": "train-2",
                "attributes": ["version": "1.4.2", "platform": "IOS"]
            ]
        ]

        let build = try XCTUnwrap(AppStoreConnectService.matchingBuild(
            builds: builds,
            included: included,
            marketingVersion: "1.4.2",
            buildNumber: "43"
        ))

        XCTAssertEqual(build.id, "matching")
        XCTAssertTrue(build.isProcessed)
        XCTAssertNil(AppStoreConnectService.matchingBuild(
            builds: builds,
            included: included,
            marketingVersion: "1.4.2",
            buildNumber: "44"
        ))
    }

    func testAutomaticInternalTestFlightGroupsDoNotNeedManualBuildAssignment() {
        XCTAssertTrue(AppStoreConnectService.betaGroupUsesAutomaticBuildAccess([
            "attributes": ["hasAccessToAllBuilds": true]
        ]))
        XCTAssertFalse(AppStoreConnectService.betaGroupUsesAutomaticBuildAccess([
            "attributes": ["hasAccessToAllBuilds": false]
        ]))
        XCTAssertFalse(AppStoreConnectService.betaGroupUsesAutomaticBuildAccess([
            "attributes": ["name": "Manual Testers"]
        ]))
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

private extension AppStorePublishingTests {
    func publicationURLTestSession(
        handler: @escaping (URLRequest) throws -> HTTPURLResponse
    ) -> URLSession {
        PublicationURLProtocolStub.configure(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicationURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    func appStoreConnectTestService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> AppStoreConnectService {
        AppStoreConnectURLProtocolStub.configure(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppStoreConnectURLProtocolStub.self]
        return try AppStoreConnectService(
            issuerID: "issuer",
            keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: URLSession(configuration: configuration)
        )
    }

    func preparePublication(
        service: AppStoreConnectService,
        intent: PublishingIntent
    ) async throws -> AppStoreConnectPublication {
        try await service.preparePublication(
            bundleIdentifier: "com.example.app",
            version: "2.2.0",
            intent: intent,
            locale: "en-US",
            metadata: AppStoreMetadata(
                description: "Description",
                keywords: "keywords",
                promotionalText: "Promotional text",
                whatsNew: "What's new"
            ),
            localizedMetadata: [],
            copyright: "2026 Example",
            supportURL: "https://example.com/support",
            marketingURL: nil,
            termsURL: nil,
            appName: "Example",
            subtitle: nil,
            privacyPolicyURL: "https://example.com/privacy",
            privacyChoicesURL: nil,
            licenseAgreementText: nil,
            review: AppStoreReviewConfiguration(
                contactFirstName: "Ada",
                contactLastName: "Lovelace",
                contactPhone: "+1 555 0100",
                contactEmail: "review@example.com",
                notes: "No login required.",
                demoAccountRequired: false,
                demoAccountName: nil,
                demoAccountPassword: nil
            ),
            releaseAutomatically: true,
            onOutput: { _ in }
        )
    }

    static func appStoreConnectResponse(
        for request: URLRequest,
        status: Int,
        json: [String: Any],
        headers: [String: String] = [:]
    ) throws -> (HTTPURLResponse, Data) {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: responseHeaders
        ))
        return (response, try JSONSerialization.data(withJSONObject: json))
    }

    static func requestBodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? AppStoreConnectError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class AppStoreConnectURLProtocolStub: URLProtocol {
    private static let state = AppStoreConnectURLProtocolState()

    static var requests: [URLRequest] { state.requests }
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { state.requestHandler }
        set { state.requestHandler = newValue }
    }

    static func configure(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        state.configure(handler: handler)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.state.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AppStoreConnectURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { handler } }
        set {
            lock.withLock {
                handler = newValue
                if newValue == nil { recordedRequests = [] }
            }
        }
    }

    func configure(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            self.handler = handler
            recordedRequests = []
        }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let currentHandler = lock.withLock { () -> ((URLRequest) throws -> (HTTPURLResponse, Data))? in
            recordedRequests.append(request)
            return handler
        }
        return try XCTUnwrap(currentHandler)(request)
    }
}

private final class PublicationURLProtocolStub: URLProtocol {
    private static let state = PublicationURLProtocolState()

    static var requests: [URLRequest] { state.requests }
    static var requestMethods: [String] { requests.compactMap(\.httpMethod) }

    static func configure(handler: @escaping (URLRequest) throws -> HTTPURLResponse) {
        state.configure(handler: handler)
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try Self.state.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class PublicationURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> HTTPURLResponse)?
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func configure(handler: @escaping (URLRequest) throws -> HTTPURLResponse) {
        lock.withLock {
            self.handler = handler
            recordedRequests = []
        }
    }

    func reset() {
        lock.withLock {
            handler = nil
            recordedRequests = []
        }
    }

    func response(for request: URLRequest) throws -> HTTPURLResponse {
        let currentHandler = lock.withLock { () -> ((URLRequest) throws -> HTTPURLResponse)? in
            recordedRequests.append(request)
            return handler
        }
        return try XCTUnwrap(currentHandler)(request)
    }
}
