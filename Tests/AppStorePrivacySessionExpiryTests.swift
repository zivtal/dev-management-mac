import XCTest
@testable import DevManagement

/// An expired Fastlane session fails deep inside Spaceship with a GitHub-issue dump
/// and "Could not receive latest API key". The publisher must turn that into the one
/// instruction that fixes it: sign in with the Apple Account button, or refresh the
/// session.
final class AppStorePrivacySessionExpiryTests: XCTestCase {
    private let expiredOutput = """
    [20:52:06]: Login to App Store Connect (someone@example.com)
    Available session is not valid anymore. Continuing with normal login.
    Session loaded from environment variable is not valid. Continuing with normal login.
    Service key is empty
    Looking for related GitHub issues on fastlane/fastlane...
    [!] The request could not be completed because:
        Could not receive latest API key from App Store Connect, this might be a server issue.
    """

    func testRecognizesAnExpiredSessionInFastlaneOutput() {
        XCTAssertTrue(AppStorePrivacyPublishingService.indicatesExpiredSession(expiredOutput))
        XCTAssertTrue(AppStorePrivacyPublishingService.indicatesExpiredSession(
            "Could not receive latest API key from App Store Connect, this might be a server issue."
        ))
        XCTAssertFalse(AppStorePrivacyPublishingService.indicatesExpiredSession(
            "[!] The request could not be completed because: Not Found"
        ))
        XCTAssertFalse(AppStorePrivacyPublishingService.indicatesExpiredSession(""))
    }

    func testPublishTranslatesAnExpiredSessionIntoASignInInstruction() async throws {
        guard let fastlane = AppStorePrivacyPublishingService.executableURL() else {
            throw XCTSkip("Fastlane is not installed; the executable lookup runs before the session check.")
        }
        let runner = RecordingProcessRunner()
        let output = expiredOutput
        runner.respond { invocation in
            guard invocation.executable == fastlane.path else { return nil }
            return CommandResult(terminationStatus: 1, output: output)
        }
        let service = AppStorePrivacyPublishingService(processRunner: runner)

        do {
            try await service.publish(
                draft: AppStorePrivacyDraft(collectsData: false, dataTypes: [], notes: []),
                bundleIdentifier: "com.example.Sample",
                appleID: "someone@example.com",
                teamID: nil,
                session: "---\n- !ruby/object:HTTP::Cookie\n  name: myacinfo\n",
                onOutput: { _ in }
            )
            XCTFail("An expired session must not report success")
        } catch AppStorePrivacyPublishingError.sessionExpired {
            let description = AppStorePrivacyPublishingError.sessionExpired.errorDescription ?? ""
            XCTAssertTrue(description.contains("Apple Account"))
            XCTAssertTrue(description.contains("fastlane spaceauth"))
            XCTAssertFalse(description.contains("github.com"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOtherFastlaneFailuresKeepTheirOutput() async throws {
        guard let fastlane = AppStorePrivacyPublishingService.executableURL() else {
            throw XCTSkip("Fastlane is not installed; the executable lookup runs before the session check.")
        }
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.executable == fastlane.path else { return nil }
            return CommandResult(terminationStatus: 1, output: "[!] App 'com.example.Sample' not found")
        }
        let service = AppStorePrivacyPublishingService(processRunner: runner)

        do {
            try await service.publish(
                draft: AppStorePrivacyDraft(collectsData: false, dataTypes: [], notes: []),
                bundleIdentifier: "com.example.Sample",
                appleID: "someone@example.com",
                teamID: nil,
                session: "cookie",
                onOutput: { _ in }
            )
            XCTFail("A failed command must throw")
        } catch ProcessRunnerError.commandFailed(_, _, let output) {
            XCTAssertTrue(output.contains("not found"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
