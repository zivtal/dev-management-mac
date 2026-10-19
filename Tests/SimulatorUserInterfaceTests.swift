import XCTest
@testable import DevManagement

/// Xcode 26 and earlier ship Simulator.app inside the developer directory.
/// Xcode 27 removed it; its Device Hub application shows simulator screens
/// instead and lives next to Xcode's other bundled applications.
final class SimulatorUserInterfaceTests: XCTestCase {
    private let developerDirectory = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
    private let simulatorApp = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
    private let deviceHubApp = "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"

    func testPrefersSimulatorAppAndTargetsTheDevice() {
        let ui = SimulatorUserInterface.locate(
            developerDirectory: developerDirectory,
            applicationExists: { $0.path == self.simulatorApp || $0.path == self.deviceHubApp }
        )

        XCTAssertEqual(ui, .simulator(URL(fileURLWithPath: simulatorApp, isDirectory: true)))
        XCTAssertEqual(ui?.openArguments(udid: "SIM-1"), [simulatorApp, "--args", "-CurrentDeviceUDID", "SIM-1"])
    }

    func testFallsBackToDeviceHubWhenSimulatorAppIsMissing() {
        let ui = SimulatorUserInterface.locate(
            developerDirectory: developerDirectory,
            applicationExists: { $0.path == self.deviceHubApp }
        )

        XCTAssertEqual(ui, .deviceHub(URL(fileURLWithPath: deviceHubApp, isDirectory: true)))
        XCTAssertEqual(ui?.openArguments(udid: "SIM-1"), [deviceHubApp])
    }

    func testReportsNoUserInterfaceWhenNeitherApplicationExists() {
        let ui = SimulatorUserInterface.locate(
            developerDirectory: developerDirectory,
            applicationExists: { _ in false }
        )

        XCTAssertNil(ui)
    }

    func testServiceOpensDeviceHubFromTheSelectedXcode() async {
        let runner = RecordingRunner(responses: [
            "xcode-select": CommandResult(terminationStatus: 0, output: "/Volumes/Beta/Xcode-beta.app/Contents/Developer\n")
        ])
        let deviceHub = "/Volumes/Beta/Xcode-beta.app/Contents/Applications/DeviceHub.app"
        let service = SimulatorService(
            processRunner: runner,
            applicationExists: { $0.path == deviceHub }
        )

        let failure = await service.openSimulatorApplication(udid: "SIM-1")

        XCTAssertNil(failure)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable.path), ["/usr/bin/xcode-select", "/usr/bin/open"])
        XCTAssertEqual(calls.last?.arguments, [deviceHub])
    }

    func testServiceReportsAMissingUserInterfaceInsteadOfOpeningByName() async {
        let runner = RecordingRunner(responses: [
            "xcode-select": CommandResult(terminationStatus: 0, output: "/Applications/Xcode.app/Contents/Developer\n")
        ])
        let service = SimulatorService(processRunner: runner, applicationExists: { _ in false })

        let failure = await service.openSimulatorApplication(udid: "SIM-1")

        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.contains("/Applications/Xcode.app") == true, failure ?? "nil")
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable.path), ["/usr/bin/xcode-select"])
    }

    func testServiceReportsWhenOpenFails() async {
        let runner = RecordingRunner(responses: [
            "xcode-select": CommandResult(terminationStatus: 0, output: "/Applications/Xcode.app/Contents/Developer\n"),
            "open": CommandResult(terminationStatus: 1, output: "LSOpenURLsWithRole() failed with error -10810")
        ])
        let service = SimulatorService(
            processRunner: runner,
            applicationExists: { $0.path == self.deviceHubApp }
        )

        let failure = await service.openSimulatorApplication(udid: "SIM-1")

        XCTAssertEqual(failure, "LSOpenURLsWithRole() failed with error -10810")
    }

    private actor RecordingRunner: ProcessRunning {
        struct Call: Equatable {
            let executable: URL
            let arguments: [String]
        }

        private(set) var calls: [Call] = []
        private let responses: [String: CommandResult]

        init(responses: [String: CommandResult]) {
            self.responses = responses
        }

        func run(
            executable: URL,
            arguments: [String],
            workingDirectory: URL?,
            additionalEnvironment: [String: String],
            standardInput: Data?,
            onOutput: ProcessRunner.OutputHandler?,
            terminateWhenOutput: ProcessRunner.OutputTerminationPredicate?
        ) async throws -> CommandResult {
            calls.append(Call(executable: executable, arguments: arguments))
            return responses[executable.lastPathComponent]
                ?? CommandResult(terminationStatus: 0, output: "")
        }
    }
}
