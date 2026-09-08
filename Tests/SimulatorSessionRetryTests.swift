import XCTest
@testable import DevManagement

@MainActor
final class SimulatorSessionRetryTests: XCTestCase {
    func testRetriesEveryFiveMinutesWithoutSourceChangesUntilSuccess() async throws {
        let fixture = try Fixture(failures: 2)
        defer { fixture.cleanup() }
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 1 }
        XCTAssertEqual(fixture.clock.durations, [.seconds(300)])
        XCTAssertEqual(fixture.session.buildCount, 1)

        fixture.clock.advance()
        try await waitUntil { fixture.clock.waits.count == 1 && fixture.session.buildCount == 2 }
        XCTAssertEqual(fixture.clock.durations, [.seconds(300), .seconds(300)])

        fixture.clock.advance()
        try await waitUntil { fixture.session.phase == .running }
        XCTAssertEqual(fixture.session.buildCount, 3)
        XCTAssertTrue(fixture.clock.waits.isEmpty)
        XCTAssertEqual(fixture.clock.durations.count, 2)
    }

    func testStopCancelsPendingRetryAndPreventsManualRebuild() async throws {
        let fixture = try Fixture(failures: 2)
        defer { fixture.cleanup() }
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 1 }

        fixture.session.stop()
        fixture.session.rebuildNow()
        fixture.clock.advance()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.session.phase, .idle)
        XCTAssertFalse(fixture.session.isSessionActive)
        XCTAssertEqual(fixture.session.buildCount, 1)
        XCTAssertEqual(fixture.clock.durations.count, 1)
    }

    func testManualRebuildSupersedesPendingRetry() async throws {
        let fixture = try Fixture(failures: 1)
        defer { fixture.cleanup() }
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 1 }

        fixture.session.rebuildNow()
        try await waitUntil { fixture.session.phase == .running }
        fixture.clock.advance() // A canceled timer waking must not start another build.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.session.buildCount, 2)
        XCTAssertEqual(fixture.session.phase, .running)
        XCTAssertEqual(fixture.clock.durations.count, 1)
    }

    func testSourceChangeRebuildsBeforeRetryIsDue() async throws {
        let fixture = try Fixture(failures: 1)
        defer { fixture.cleanup() }
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 1 }
        try "let fixed = true\n".write(
            to: fixture.folder.appendingPathComponent("Main.swift"),
            atomically: true,
            encoding: .utf8
        )
        fixture.session.handleSourceChange()
        try await waitUntil { fixture.session.phase == .running }
        fixture.clock.advance()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.session.buildCount, 2)
        XCTAssertEqual(fixture.clock.durations.count, 1)
    }

    func testCanceledRetryCannotAffectRestartedSession() async throws {
        let fixture = try Fixture(failures: 2)
        defer { fixture.cleanup() }
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 1 }
        fixture.session.stop()
        fixture.session.start(settings: SimulatorRunSettings())
        try await waitUntil { fixture.clock.waits.count == 2 }

        fixture.clock.advance() // Timer belonging to the stopped session.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.session.buildCount, 1)
        XCTAssertEqual(fixture.session.phase, .failed)

        fixture.clock.advance()
        try await waitUntil { fixture.session.phase == .running }
        XCTAssertEqual(fixture.session.buildCount, 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for simulator session")
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum TestError: Error { case timeout }

    @MainActor
    private final class RetryClock {
        var durations: [Duration] = []
        var waits: [CheckedContinuation<Void, Error>] = []

        func sleep(for duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { waits.append($0) }
        }

        func advance() {
            waits.removeFirst().resume()
        }
    }

    @MainActor
    private final class Fixture {
        let folder: URL
        let clock = RetryClock()
        let session: SimulatorSessionController

        init(failures: Int) throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimulatorRetry-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = ProjectDescriptor(
                displayName: "Example",
                folderPath: folder.path,
                containerPath: folder.appendingPathComponent("Example.xcodeproj").path,
                containerKind: .project,
                schemes: ["Example"],
                configurations: ["Debug"]
            ).makeManagedProject()
            session = SimulatorSessionController(
                project: project,
                simulatorService: SimulatorService(processRunner: SimulatorRunner()),
                installationService: Builder(failures: failures),
                derivedDataURL: folder.appendingPathComponent("DerivedData"),
                retrySleep: { [clock] in try await clock.sleep(for: $0) }
            )
        }

        func cleanup() {
            session.stop()
            while !clock.waits.isEmpty { clock.advance() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private actor Builder: SimulatorBuilding {
        var failures: Int

        init(failures: Int) { self.failures = failures }

        func buildForSimulator(
            project: ManagedProject,
            simulatorUDID: String,
            derivedDataURL: URL,
            eventHandler: @escaping InstallationService.EventHandler
        ) async throws -> SimulatorBuildProduct {
            if failures > 0 {
                failures -= 1
                throw ProcessRunnerError.commandFailed(
                    executable: "xcodebuild", status: 65, output: "error: broken source"
                )
            }
            return SimulatorBuildProduct(
                applicationURL: derivedDataURL.appendingPathComponent("Example.app"),
                bundleIdentifier: "com.example.app"
            )
        }
    }

    private struct SimulatorRunner: ProcessRunning {
        func run(
            executable: URL,
            arguments: [String],
            workingDirectory: URL?,
            additionalEnvironment: [String: String],
            standardInput: Data?,
            onOutput: ProcessRunner.OutputHandler?,
            terminateWhenOutput: ProcessRunner.OutputTerminationPredicate?
        ) async throws -> CommandResult {
            let output = arguments.starts(with: ["simctl", "list"]) ? """
                {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
                    {"udid":"TEST-SIM","name":"iPhone 17 Pro","state":"Booted","isAvailable":true}
                ]}}
                """ : ""
            return CommandResult(terminationStatus: 0, output: output)
        }
    }
}
