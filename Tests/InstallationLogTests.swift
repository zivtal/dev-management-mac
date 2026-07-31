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
}
