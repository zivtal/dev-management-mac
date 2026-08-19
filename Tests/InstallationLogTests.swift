import XCTest
@testable import DevManagement

final class InstallationLogTests: XCTestCase {
    func testLogAppendsEveryOutputChunkAndTracksLatestLine() {
        var log = InstallationLogSession(projectName: "TripFlow", deviceName: "iPhone")

        log.append("Compile Swift\n")
        log.append("Link TripFlow\nCodeSign TripFlow\n")

        XCTAssertEqual(log.output, "Compile Swift\nLink TripFlow\nCodeSign TripFlow\n")
        XCTAssertEqual(log.latestOutputLine, "CodeSign TripFlow")
        XCTAssertEqual(log.revision, 2)
    }

    func testEmptyChunksDoNotAdvanceLogRevision() {
        var log = InstallationLogSession(projectName: "TripFlow", deviceName: "iPhone")

        log.append("")

        XCTAssertEqual(log.output, "")
        XCTAssertEqual(log.revision, 0)
    }

    func testLongLiveLogKeepsOnlyRecentOutput() {
        var log = InstallationLogSession(projectName: "TripFlow", deviceName: "iPhone")

        log.append(String(repeating: "A", count: 31_000))
        log.append("latest output")

        XCTAssertTrue(log.output.hasPrefix("…\n"))
        XCTAssertTrue(log.output.hasSuffix("latest output"))
        XCTAssertEqual(log.output.count, 30_002)
    }

    func testInstallationEventBatchKeepsLatestPhaseAndCombinesOutput() {
        var batch = InstallationEventBatch()

        batch.append(.phase(.building))
        batch.append(.output("Compile Swift\n"))
        batch.append(.output("Link TripFlow\n"))
        batch.append(.phase(.installing))

        XCTAssertEqual(batch.phase, .installing)
        XCTAssertEqual(batch.output, "Compile Swift\nLink TripFlow\n")
    }

    func testInstallationEventCoalescerFlushesBurstAsOneBatch() {
        let coalescer = InstallationEventCoalescer(deliveryInterval: 5) { _ in }

        for index in 0..<100 {
            coalescer.receive(.output("line \(index)\n"))
        }
        let batch = coalescer.finish()

        XCTAssertEqual(batch.output.components(separatedBy: .newlines).count - 1, 100)
    }

    func testCancelledInstallationLogHasCancelledStatus() {
        var log = InstallationLogSession(projectName: "TripFlow", deviceName: "iPhone")

        log.state = .cancelled

        XCTAssertEqual(log.statusTitle, L10n.text("Installation canceled"))
    }

    func testFinishedInstallationRuntimeStopsAtFinishedDate() {
        let start = Date(timeIntervalSince1970: 100)
        let finish = Date(timeIntervalSince1970: 165)
        let log = InstallationLogSession(
            projectName: "TripFlow",
            deviceName: "iPhone",
            startedAt: start,
            finishedAt: finish,
            state: .succeeded
        )

        XCTAssertEqual(log.elapsedTime(at: Date(timeIntervalSince1970: 500)), 65)
    }

    func testRuntimeTextOmitsZeroValuedComponents() {
        XCTAssertEqual(RuntimeDurationFormatter.string(from: 138), "2m 18s")
        XCTAssertEqual(RuntimeDurationFormatter.string(from: 7_218), "2h 18s")
        XCTAssertEqual(RuntimeDurationFormatter.string(from: 7_200), "2h")
    }
}

final class ProcessRunnerCancellationTests: XCTestCase {
    func testCommandFailureSummaryKeepsDiagnosticsAndDropsSchemeEnvironment() {
        let summary = CommandFailureSummary.text(from: """
        Run pre-actions
        export ACTION=install
        export BUILD_DIR=/tmp/build
        /Example/SubscriptionService.swift:51:22: error: cannot find type 'SubscriptionTrialPolicy' in scope
        /Example/SubscriptionService.swift:51:22: error: cannot find type 'SubscriptionTrialPolicy' in scope
        ** ARCHIVE FAILED **
        """)

        XCTAssertFalse(summary.contains("export ACTION"))
        XCTAssertEqual(
            summary,
            """
            /Example/SubscriptionService.swift:51:22: error: cannot find type 'SubscriptionTrialPolicy' in scope
            ** ARCHIVE FAILED **
            """
        )
    }

    func testCancellingTaskStopsRunningCommand() async throws {
        let task = Task {
            try await ProcessRunner().runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A canceled command should not complete successfully")
        } catch is CancellationError {
            // Expected: ProcessRunner propagates task cancellation after stopping the process.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testOutputTerminationPredicateStopsRunningCommand() async throws {
        let start = Date()

        do {
            _ = try await ProcessRunner().runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo poisoned-upload; exec /bin/sleep 30"],
                terminateWhenOutput: { $0.contains("poisoned-upload") }
            )
            XCTFail("The command should be terminated after matching its output")
        } catch ProcessRunnerError.commandFailed {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        } catch {
            XCTFail("Expected a command failure, received \(error)")
        }
    }
}
