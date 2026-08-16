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
