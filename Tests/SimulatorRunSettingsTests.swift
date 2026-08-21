import XCTest
@testable import DevManagement

final class SimulatorRunSettingsTests: XCTestCase {
    func testDefaultDebugNowVariableNameNormalizesScheme() {
        XCTAssertEqual(
            SimulatorRunSettings.defaultDebugNowVariableName(forScheme: "TripFlow"),
            "TRIPFLOW_DEBUG_NOW"
        )
        XCTAssertEqual(
            SimulatorRunSettings.defaultDebugNowVariableName(forScheme: "My App-2"),
            "MY_APP_2_DEBUG_NOW"
        )
        XCTAssertEqual(
            SimulatorRunSettings.defaultDebugNowVariableName(forScheme: "1Password"),
            "_1PASSWORD_DEBUG_NOW"
        )
    }

    func testEffectiveVariableNamePrefersExplicitName() {
        var settings = SimulatorRunSettings()
        settings.debugNowVariableName = "  CUSTOM_NOW  "
        XCTAssertEqual(
            settings.effectiveDebugNowVariableName(forScheme: "TripFlow"),
            "CUSTOM_NOW"
        )
        settings.debugNowVariableName = "   "
        XCTAssertEqual(
            settings.effectiveDebugNowVariableName(forScheme: "TripFlow"),
            "TRIPFLOW_DEBUG_NOW"
        )
    }

    func testSimulatedNowWithDateOnlyUsesBareDate() {
        var settings = SimulatorRunSettings()
        settings.simulatedDate = "2026-03-15"
        XCTAssertEqual(settings.simulatedNowValue(), "2026-03-15")
    }

    func testSimulatedNowWithDateAndTimeCarriesUTCOffset() throws {
        var settings = SimulatorRunSettings()
        settings.simulatedDate = "2026-03-15"
        settings.simulatedTime = "08:30"
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 3600))
        XCTAssertEqual(
            settings.simulatedNowValue(timeZone: timeZone),
            "2026-03-15T08:30:00+02:00"
        )
    }

    func testSimulatedNowWithNegativeOffsetTimeZone() throws {
        var settings = SimulatorRunSettings()
        settings.simulatedDate = "2026-03-15"
        settings.simulatedTime = "22:05"
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -(5 * 3600 + 30 * 60)))
        XCTAssertEqual(
            settings.simulatedNowValue(timeZone: timeZone),
            "2026-03-15T22:05:00-05:30"
        )
    }

    func testSimulatedNowWithTimeOnlyDefaultsDateToToday() throws {
        var settings = SimulatorRunSettings()
        settings.simulatedTime = "12:00"
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
        XCTAssertEqual(
            settings.simulatedNowValue(timeZone: timeZone, now: now),
            "2023-11-14T12:00:00+00:00"
        )
    }

    func testSimulatedNowIsNilWithoutDateOrTime() {
        XCTAssertNil(SimulatorRunSettings().simulatedNowValue())
    }

    func testLaunchEnvironmentUsesSimctlChildPrefix() throws {
        var settings = SimulatorRunSettings()
        settings.simulatedDate = "2026-01-02"
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(
            settings.launchEnvironment(forScheme: "TripFlow", timeZone: timeZone),
            ["SIMCTL_CHILD_TRIPFLOW_DEBUG_NOW": "2026-01-02"]
        )
        XCTAssertTrue(
            SimulatorRunSettings().launchEnvironment(forScheme: "TripFlow").isEmpty
        )
    }

    func testLaunchArgumentsWrapLanguageLikeRunEmulatorScript() {
        var settings = SimulatorRunSettings()
        XCTAssertEqual(settings.launchArguments, [])
        settings.language = "he"
        XCTAssertEqual(settings.launchArguments, ["-AppleLanguages", "(he)"])
    }

    func testLocationArgumentRequiresEnabledCoordinates() {
        var settings = SimulatorRunSettings()
        settings.latitude = 34.6937
        settings.longitude = 135.5023
        XCTAssertNil(settings.locationArgument)
        settings.isLocationEnabled = true
        XCTAssertEqual(settings.locationArgument, "34.6937,135.5023")
    }

    func testValidators() {
        XCTAssertTrue(SimulatorRunSettings.isValidDate("2026-08-21"))
        XCTAssertFalse(SimulatorRunSettings.isValidDate("21-08-2026"))
        XCTAssertTrue(SimulatorRunSettings.isValidTime("23:59"))
        XCTAssertFalse(SimulatorRunSettings.isValidTime("24:00"))
        XCTAssertTrue(SimulatorRunSettings.isValidCoordinate(latitude: -33.9, longitude: 151.2))
        XCTAssertFalse(SimulatorRunSettings.isValidCoordinate(latitude: 91, longitude: 0))
        XCTAssertFalse(SimulatorRunSettings.isValidCoordinate(latitude: 0, longitude: 181))
    }

    func testSettingsRoundTripThroughManagedProjectCoding() throws {
        var project = ProjectDescriptor(
            displayName: "TripFlow",
            folderPath: "/tmp/tripflow",
            containerPath: "/tmp/tripflow/TripFlow.xcodeproj",
            containerKind: .project,
            schemes: ["TripFlow"],
            configurations: ["Debug"]
        ).makeManagedProject()
        var settings = SimulatorRunSettings()
        settings.deviceUDID = "UDID-1"
        settings.isLocationEnabled = true
        settings.latitude = 34.6937
        settings.longitude = 135.5023
        settings.simulatedDate = "2026-08-21"
        settings.simulatedTime = "09:00"
        settings.language = "he"
        settings.debugNowVariableName = "TRIPFLOW_DEBUG_NOW"
        project.simulatorRunSettings = settings

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ManagedProject.self, from: data)
        XCTAssertEqual(decoded.simulatorRunSettings, settings)
    }
}
