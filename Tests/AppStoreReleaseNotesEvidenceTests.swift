import XCTest
@testable import DevManagement

final class AppStoreReleaseNotesEvidenceTests: XCTestCase {
    func testFullReleaseIntervalRetainsFeatureIntroductionAndWorkingChanges() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 1.0.0\n")
        try await fixture.commit("Approved release")
        try await fixture.git(["tag", "V1.0.0"])
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 1.0.1\n")
        try fixture.write("Chat.swift", "struct TripChat { let title = \"Ask AI about your trip\" }\n")
        try await fixture.commit("Introduce persistent AI trip chat")
        for index in 1...85 {
            try fixture.write("Plan.swift", "struct PlanLayout { let revision = \(index) }\n")
            try await fixture.commit("Refine day plan layout \(index)")
        }
        try fixture.write("Chat.swift", "struct TripChat { let title = \"Ask AI about your trip and expenses\" }\n")
        try await fixture.git(["add", "Chat.swift"])
        try fixture.write("Chat.swift", "struct TripChat { let title = \"Ask AI about your trip, expenses and hotels\" }\n")

        let result = try await fixture.evidence()
        let evidence = try XCTUnwrap(result)

        XCTAssertTrue(evidence.sourceDescription.contains("V1.0.0"))
        XCTAssertTrue(evidence.content.contains("Introduce persistent AI trip chat"))
        XCTAssertTrue(evidence.content.contains("Refine day plan layout 85"))
        XCTAssertTrue(evidence.content.contains("A\tChat.swift"))
        XCTAssertTrue(evidence.content.contains("Ask AI about your trip, expenses and hotels"))
        XCTAssertFalse(evidence.content.contains("Approved release"))
        XCTAssertLessThan(evidence.content.count, 108_000)
    }

    func testVersionBaselineIgnoresReadmePublishingMetadataAndOtherBranches() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 1.0.0\n")
        try await fixture.commit("Approved release")
        let baseline = try await fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 1.0.1\n")
        try fixture.write("Chat.swift", "struct NewAIChat {}\n")
        try await fixture.commit("Introduce AI chat while bumping away from approved version")
        try fixture.write("README.md", "## 1.0.1\nLatest layout refinements only.\n\nPrevious version: 1.0.0\n")
        try fixture.write("app-store-publishing.json", "{\"previousApprovedVersion\":\"1.0.0\"}\n")
        try await fixture.commit("Document previous approved version after chat was added")
        // Even an exact version declaration on another branch must not move the baseline.
        try await fixture.git(["checkout", "-b", "unrelated-release"])
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 1.0.0\n")
        try await fixture.commit("Unrelated version reuse")
        try await fixture.git(["tag", "v1.0.0"])
        try await fixture.git(["checkout", "-"])

        let result = try await fixture.evidence()
        let evidence = try XCTUnwrap(result)

        XCTAssertEqual(evidence.source, .combined)
        XCTAssertTrue(evidence.content.contains("Git baseline: \(baseline)"))
        XCTAssertTrue(evidence.content.contains("Introduce AI chat while bumping away from approved version"))
        XCTAssertTrue(evidence.content.contains("A\tChat.swift"))
        XCTAssertFalse(evidence.content.contains("Unrelated version reuse"))
    }

    func testUnknownBaselineDoesNotPretendRecentHistoryIsTheReleaseInterval() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        try fixture.write("Version.xcconfig", "MARKETING_VERSION = 11.0.0\n")
        try fixture.write("README.md", "## 1.0.1\nRelease notes for latest tweaks.\nPrevious release: 1.0.0\n")
        try await fixture.commit("A recent change mentioning 1.0.0")

        do {
            _ = try await fixture.evidence()
            XCTFail("A README mention must not qualify as a release baseline")
        } catch OpenAIStoreMetadataError.missingReleaseBaseline(let version) {
            XCTAssertEqual(version, "1.0.0")
        }
    }

    func testVersionDeclarationsRequireAnExactMarketingVersion() {
        for contents in [
            "MARKETING_VERSION = 1.0.0;",
            "    MARKETING_VERSION: \"1.0.0\"\n",
            "MARKETING_VERSION = 1.0.0 // approved",
            "<key>CFBundleShortVersionString</key>\n<string>1.0.0</string>"
        ] {
            XCTAssertTrue(AppStoreReleaseNotesEvidenceService.containsMarketingVersion("1.0.0", in: contents), contents)
        }
        for contents in [
            "MARKETING_VERSION = 11.0.0;", "MARKETING_VERSION = 1.0.01;",
            "Previous version 1.0.0", "// MARKETING_VERSION = 1.0.0",
            "CURRENT_PROJECT_VERSION = 1.0.0", "MARKETING_VERSION = $(VERSION)"
        ] {
            XCTAssertFalse(AppStoreReleaseNotesEvidenceService.containsMarketingVersion("1.0.0", in: contents), contents)
        }
    }

    private struct Repository {
        let root: URL
        let runner = ProcessRunner()

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseEvidence-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await git(["init"])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, _ contents: String) throws {
            try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            try await runner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, workingDirectory: root
            ).output
        }

        func commit(_ message: String) async throws {
            try await git(["add", "."])
            try await git([
                "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message
            ])
        }

        func evidence() async throws -> AppStoreReleaseNotesEvidence? {
            let project = ManagedProject(
                id: UUID(), displayName: "Example", folderPath: root.path,
                containerPath: root.appendingPathComponent("Example.xcodeproj").path,
                containerKind: .project, scheme: "Example", configuration: "Release",
                availableSchemes: ["Example"], availableConfigurations: ["Release"],
                isEnabled: true, marketingVersion: "1.0.1", buildNumber: "2"
            )
            return try await AppStoreReleaseNotesEvidenceService().evidence(
                project: project, previousVersion: "1.0.0", currentVersion: "1.0.1"
            )
        }
    }
}
