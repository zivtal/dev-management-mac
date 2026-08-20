import XCTest
@testable import DevManagement

final class PublishingExperienceTests: XCTestCase {
    func testPublishingActionsHaveExplicitReviewBehavior() {
        XCTAssertTrue(PublishingIntent.publish.submitsForReview)
        XCTAssertFalse(PublishingIntent.testFlight.submitsForReview)
    }

    func testJourneyGroupsTechnicalPhasesIntoFiveFriendlyStages() {
        XCTAssertEqual(PublishingProgress.Phase.preparing.journeyStage, .prepare)
        XCTAssertEqual(PublishingProgress.Phase.collectingScreenshots.journeyStage, .prepare)
        XCTAssertEqual(PublishingProgress.Phase.archiving.journeyStage, .build)
        XCTAssertEqual(PublishingProgress.Phase.configuringSubscriptions.journeyStage, .configure)
        XCTAssertEqual(PublishingProgress.Phase.waitingForBuild.journeyStage, .testFlight)
        XCTAssertEqual(PublishingProgress.Phase.uploadingReviewAssets.journeyStage, .review)
        XCTAssertEqual(PublishingProgress.Phase.submitting.journeyStage, .review)
    }

    func testTechnicalPhaseCompletionIncreasesMonotonically() {
        let values = PublishingProgress.Phase.allCases.map(\.completionFraction)

        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 < $0.1 })
    }

    func testReadinessBlocksWhileCheckingOrWhenAnItemIsBlocked() {
        let ready = PublishingReadinessItem(
            id: "ready",
            title: "Ready",
            detail: "Ready",
            state: .ready
        )
        let attention = PublishingReadinessItem(
            id: "attention",
            title: "Attention",
            detail: "Optional choice",
            state: .attention
        )
        XCTAssertTrue(PublishingReadinessReport(items: [ready, attention]).allowsPublication)

        let checking = PublishingReadinessItem(
            id: "checking",
            title: "Checking",
            detail: "Checking",
            state: .checking
        )
        XCTAssertFalse(PublishingReadinessReport(items: [ready, checking]).allowsPublication)

        let blocked = PublishingReadinessItem(
            id: "blocked",
            title: "Blocked",
            detail: "Blocked",
            state: .blocked
        )
        XCTAssertFalse(PublishingReadinessReport(items: [ready, blocked]).allowsPublication)
    }

    func testTestFlightAccountReadinessDoesNotWaitForReleaseSnapshot() {
        let configured = TestFlightReadinessPolicy.accountItem(credentialIsComplete: true)
        let missing = TestFlightReadinessPolicy.accountItem(credentialIsComplete: false)

        XCTAssertEqual(configured.state, .ready)
        XCTAssertEqual(missing.state, .blocked)
    }

    func testOlderLocalMarketingVersionIsDetected() {
        XCTAssertTrue(AppStoreVersionComparison.localArtifactIsOlder(
            localVersion: "1.7.7",
            localBuild: "78",
            remoteVersion: "1.9.8",
            remoteBuild: "99"
        ))
        XCTAssertFalse(AppStoreVersionComparison.localArtifactIsOlder(
            localVersion: "1.9.9",
            localBuild: "100",
            remoteVersion: "1.9.8",
            remoteBuild: "99"
        ))
    }

    func testOlderBuildOfSameMarketingVersionIsDetected() {
        XCTAssertTrue(AppStoreVersionComparison.localArtifactIsOlder(
            localVersion: "1.9.8",
            localBuild: "98",
            remoteVersion: "1.9.8",
            remoteBuild: "99"
        ))
        XCTAssertFalse(AppStoreVersionComparison.localArtifactIsOlder(
            localVersion: "1.9.8",
            localBuild: "100",
            remoteVersion: "1.9.8",
            remoteBuild: "99"
        ))
    }

    func testFirstReleaseShowsAppStoreActionOnlyAfterMatchingTestFlightBuild() {
        XCTAssertFalse(AppStoreReleaseActionPolicy.showsAppStoreAction(
            hasReleasedVersion: false,
            hasMatchingTestFlightBuild: false
        ))
        XCTAssertTrue(AppStoreReleaseActionPolicy.showsAppStoreAction(
            hasReleasedVersion: false,
            hasMatchingTestFlightBuild: true
        ))
        XCTAssertTrue(AppStoreReleaseActionPolicy.showsAppStoreAction(
            hasReleasedVersion: true,
            hasMatchingTestFlightBuild: false
        ))
    }

    func testPrivacyConfigurationRequiresTheAppropriateReviewBeforeSaving() {
        XCTAssertEqual(
            AppStorePrivacyConfigurationPolicy.state(for: nil),
            .missingDraft
        )
        XCTAssertEqual(
            AppStorePrivacyConfigurationPolicy.state(for: AppStoreComplianceConfiguration(
                privacyDraft: AppStorePrivacyDraft(collectsData: false, dataTypes: [], notes: []),
                privacyAttestation: nil,
                evidence: nil,
                confidence: nil
            )),
            .needsAutomaticAuthorization
        )
        XCTAssertEqual(
            AppStorePrivacyConfigurationPolicy.state(for: AppStoreComplianceConfiguration(
                privacyDraft: AppStorePrivacyDraft(
                    collectsData: true,
                    dataTypes: ["Identifiers"],
                    notes: []
                ),
                privacyAttestation: nil,
                evidence: nil,
                confidence: nil
            )),
            .needsManualConfirmation
        )
    }

    func testPrivacyConfigurationAcceptsAutomaticOrManualConfirmation() {
        let automatic = AppStorePrivacyAttestation(
            confirmedBy: "Publisher",
            confirmedAt: "2026-08-17T13:00:00Z",
            projectFingerprint: nil,
            automaticPublishingAuthorizedAt: "2026-08-17T13:00:00Z"
        )
        XCTAssertEqual(
            AppStorePrivacyConfigurationPolicy.state(for: AppStoreComplianceConfiguration(
                privacyDraft: AppStorePrivacyDraft(collectsData: false, dataTypes: [], notes: []),
                privacyAttestation: automatic,
                evidence: nil,
                confidence: nil
            )),
            .automaticallyAuthorized
        )

        let manual = AppStorePrivacyAttestation(
            confirmedBy: "Publisher",
            confirmedAt: "2026-08-17T13:00:00Z",
            projectFingerprint: nil
        )
        XCTAssertEqual(
            AppStorePrivacyConfigurationPolicy.state(for: AppStoreComplianceConfiguration(
                privacyDraft: AppStorePrivacyDraft(
                    collectsData: true,
                    dataTypes: ["Identifiers"],
                    notes: []
                ),
                privacyAttestation: manual,
                evidence: nil,
                confidence: nil
            )),
            .confirmed
        )
    }

    func testCustomOfferCodeBuildsAppleRedemptionURL() throws {
        let url = try XCTUnwrap(SubscriptionOfferCodeRedemption.url(
            appID: "1234567890",
            code: "PRESS & FRIENDS"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "apps.apple.com")
        XCTAssertEqual(components.path, "/redeem")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }),
            ["ctx": "offercodes", "id": "1234567890", "code": "PRESS & FRIENDS"]
        )
    }

    func testNoDataPrivacyPayloadAndSessionNormalization() throws {
        let payload = try AppStorePrivacyPublishingService.payload(for: AppStorePrivacyDraft(
            collectsData: false,
            dataTypes: [],
            notes: []
        ))

        XCTAssertEqual(payload, [FastlaneAppPrivacyUsage(dataProtections: ["DATA_NOT_COLLECTED"])])
        XCTAssertEqual(
            AppStorePrivacyPublishingService.normalizedSession("export FASTLANE_SESSION='cookie value'\n"),
            "cookie value"
        )
        XCTAssertThrowsError(try AppStorePrivacyPublishingService.payload(for: AppStorePrivacyDraft(
            collectsData: true,
            dataTypes: ["Identifiers"],
            notes: []
        )))
    }

    func testOfferCodeBatchesSortAvailableFirstAndNewestWithinState() {
        let inactive = AppStoreConnectCustomCodeBatchSnapshot(
            id: "inactive",
            customCode: "OLD",
            numberOfCodes: 500,
            createdDate: "2026-08-17T10:00:00Z",
            expirationDate: nil,
            active: false,
            redemptionURL: nil
        )
        let olderActive = AppStoreConnectCustomCodeBatchSnapshot(
            id: "older-active",
            customCode: "FIRST",
            numberOfCodes: 500,
            createdDate: "2026-08-17T11:00:00Z",
            expirationDate: nil,
            active: true,
            redemptionURL: nil
        )
        let newerActive = AppStoreConnectCustomCodeBatchSnapshot(
            id: "newer-active",
            customCode: "SECOND",
            numberOfCodes: 500,
            createdDate: "2026-08-17T12:00:00Z",
            expirationDate: nil,
            active: true,
            redemptionURL: nil
        )

        XCTAssertEqual(
            SubscriptionOfferCodeAvailabilityOrdering.custom([
                inactive,
                olderActive,
                newerActive
            ]).map(\.id),
            ["newer-active", "older-active", "inactive"]
        )
    }

    func testAppStoreFallbackPrefersMatchingLocaleAndKeepsReviewDetails() {
        let review = AppStoreConnectReviewSnapshot(
            contactFirstName: "Ada",
            contactLastName: "Lovelace",
            contactPhone: "+1 555 0100",
            contactEmail: "review@example.com",
            notes: "No login required.",
            demoAccountRequired: false
        )
        let snapshot = AppStoreConnectConfigurationSnapshot(
            appName: "Example",
            bundleIdentifier: "com.example.app",
            sku: nil,
            primaryLocale: "en-US",
            contentRightsDeclaration: nil,
            primaryCategory: nil,
            secondaryCategory: nil,
            ageRating: nil,
            licenseAgreementText: nil,
            licenseTerritoryIDs: [],
            territoryIDs: ["ISR", "USA"],
            appLocalizations: [],
            version: AppStoreConnectVersionSnapshot(
                versionString: "1.0.0",
                state: "PREPARE_FOR_SUBMISSION",
                buildNumber: "1",
                releaseType: nil,
                copyright: "2026 Example",
                earliestReleaseDate: nil,
                localizations: [
                    AppStoreConnectVersionLocalizationSnapshot(
                        locale: "en-US",
                        description: nil,
                        keywords: nil,
                        promotionalText: nil,
                        whatsNew: nil,
                        supportURL: "https://example.com/support",
                        marketingURL: nil,
                        screenshotCounts: [:]
                    ),
                    AppStoreConnectVersionLocalizationSnapshot(
                        locale: "he",
                        description: nil,
                        keywords: nil,
                        promotionalText: nil,
                        whatsNew: nil,
                        supportURL: "https://example.com/he/support",
                        marketingURL: nil,
                        screenshotCounts: [:]
                    )
                ],
                review: review
            ),
            testFlightBuild: nil,
            activeReviewVersion: nil,
            latestApprovedVersion: nil,
            hasReadyForDistributionVersion: false,
            subscriptionGroups: [],
            loadedAt: Date()
        )

        let fallback = snapshot.publicationFallback(preferredLocale: "he-IL")

        XCTAssertEqual(fallback.supportURL, "https://example.com/he/support")
        XCTAssertEqual(fallback.copyright, "2026 Example")
        XCTAssertEqual(fallback.review, review)
    }

    func testOfferCodeCSVReturnsOnlyCopyableCodes() {
        let csv = Data("Offer Code,Redemption URL\nFREECODE2026,https://apps.apple.com/redeem?code=FREECODE2026\nSECOND2026,https://apps.apple.com/redeem?code=SECOND2026\n".utf8)

        XCTAssertEqual(
            SubscriptionOfferCodeCSV.values(from: csv),
            ["FREECODE2026", "SECOND2026"]
        )
    }

    func testOfferCodeCSVHandlesQuotedFieldsAndURLOnlyRows() {
        let csv = Data("\"Redemption URL\"\n\"https://apps.apple.com/redeem?code=COPYME\"\n".utf8)

        XCTAssertEqual(SubscriptionOfferCodeCSV.values(from: csv), ["COPYME"])
    }

    func testProductionOfferCodeBatchSizeUsesAppStoreConnectLimits() {
        XCTAssertFalse(SubscriptionOfferCodeBatchSize.isValid(499))
        XCTAssertTrue(SubscriptionOfferCodeBatchSize.isValid(500))
        XCTAssertTrue(SubscriptionOfferCodeBatchSize.isValid(25_000))
        XCTAssertFalse(SubscriptionOfferCodeBatchSize.isValid(25_001))
    }

    func testOfferCodeExpirationTreatsDisplayedSixMonthDateAsValid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Jerusalem"))
        let referenceDate = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 15, minute: 30)
        ))
        let displayedExpiration = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 2, day: 17, hour: 15, minute: 30)
        ))

        XCTAssertTrue(SubscriptionOfferCodeExpiration.isValid(
            displayedExpiration,
            relativeTo: referenceDate,
            calendar: calendar
        ))
    }

    func testOfferCodeExpirationRejectsTodayAndDateAfterSixMonthLimit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Jerusalem"))
        let referenceDate = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 15, minute: 30)
        ))
        let afterLimit = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 2, day: 18)
        ))

        XCTAssertFalse(SubscriptionOfferCodeExpiration.isValid(
            referenceDate,
            relativeTo: referenceDate,
            calendar: calendar
        ))
        XCTAssertFalse(SubscriptionOfferCodeExpiration.isValid(
            afterLimit,
            relativeTo: referenceDate,
            calendar: calendar
        ))
    }

    func testOfferCodeExpirationUsesPacificDateBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Jerusalem"))
        let referenceDate = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 7, minute: 8)
        ))
        let pacificSixMonthLimit = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 2, day: 16)
        ))
        let localSixMonthLimit = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 2, day: 17)
        ))

        XCTAssertEqual(
            SubscriptionOfferCodeExpiration.latestDate(
                from: referenceDate,
                calendar: calendar
            ),
            pacificSixMonthLimit
        )
        XCTAssertTrue(SubscriptionOfferCodeExpiration.isValid(
            pacificSixMonthLimit,
            relativeTo: referenceDate,
            calendar: calendar
        ))
        XCTAssertFalse(SubscriptionOfferCodeExpiration.isValid(
            localSixMonthLimit,
            relativeTo: referenceDate,
            calendar: calendar
        ))
    }

    func testSubscriptionPriceValidationNormalizesCommaDecimalSeparator() {
        XCTAssertEqual(SubscriptionPriceValidation.normalized(" 89,90 "), "89.90")
        XCTAssertEqual(SubscriptionPriceValidation.normalized("9.9"), "9.9")
    }

    func testSubscriptionPriceValidationRejectsEmptyZeroAndNegativeValues() {
        XCTAssertNil(SubscriptionPriceValidation.normalized(""))
        XCTAssertNil(SubscriptionPriceValidation.normalized("0"))
        XCTAssertNil(SubscriptionPriceValidation.normalized("-1"))
        XCTAssertNil(SubscriptionPriceValidation.normalized("price"))
    }
}
