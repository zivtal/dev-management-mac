import XCTest
@testable import DevManagement

final class SimulatorExtensionRestartTests: XCTestCase {
    func testRestartTerminatesTheInstalledAppsExtensionProcesses() async {
        let runner = RecordingRunner(terminationStatus: 0)
        let service = SimulatorService(processRunner: runner)

        await service.restartApplicationExtensions(udid: "TEST-SIM", applicationName: "Trip Flow.app")

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.executable.path, "/usr/bin/pkill")
        XCTAssertEqual(calls.first?.arguments, [
            "-TERM", "-f",
            "/Devices/TEST-SIM/data/Containers/Bundle/Application/[^/]+/Trip Flow\\.app/PlugIns/"
        ])
    }

    func testPatternMatchesOnlyExtensionsInsideTheAppBundleOnThatDevice() throws {
        let pattern = SimulatorService.extensionProcessPattern(udid: "SIM-1", applicationName: "TripFlow.app")
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ command: String) -> Bool {
            regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }

        XCTAssertTrue(matches(
            "/Users/me/Library/Developer/CoreSimulator/Devices/SIM-1/data/Containers/Bundle/Application/ABC/TripFlow.app/PlugIns/TripFlowWidget.appex/TripFlowWidget -LaunchArguments x"
        ))
        XCTAssertFalse(matches(
            "/Users/me/Library/Developer/CoreSimulator/Devices/SIM-1/data/Containers/Bundle/Application/ABC/TripFlow.app/TripFlow -AppleLanguages (he)"
        ))
        XCTAssertFalse(matches(
            "/Users/me/Library/Developer/CoreSimulator/Devices/SIM-2/data/Containers/Bundle/Application/ABC/TripFlow.app/PlugIns/TripFlowWidget.appex/TripFlowWidget"
        ))
        XCTAssertFalse(matches(
            "/Users/me/Library/Developer/CoreSimulator/Devices/SIM-1/data/Containers/Bundle/Application/ABC/TripFlowXapp/PlugIns/W.appex/W"
        ))
    }

    func testNoRunningExtensionIsNotAFailure() async {
        let runner = RecordingRunner(terminationStatus: 1) // pkill: no process matched.
        let service = SimulatorService(processRunner: runner)

        await service.restartApplicationExtensions(udid: "TEST-SIM", applicationName: "Example.app")

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    private actor RecordingRunner: ProcessRunning {
        struct Call: Equatable {
            let executable: URL
            let arguments: [String]
        }

        private(set) var calls: [Call] = []
        private let terminationStatus: Int32

        init(terminationStatus: Int32) {
            self.terminationStatus = terminationStatus
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
            return CommandResult(terminationStatus: terminationStatus, output: "")
        }
    }
}
