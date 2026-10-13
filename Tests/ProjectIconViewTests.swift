import AppKit
import SwiftUI
import XCTest
@testable import DevManagement

@MainActor
final class ProjectIconViewTests: XCTestCase {
    func testIconRendersWithoutAnAppModelEnvironmentObject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("icon.tiff")
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        try XCTUnwrap(image.tiffRepresentation).write(to: imageURL)

        // Exercise a discovered icon and both fallback paths in an isolated host,
        // as used by AppKit-backed SwiftUI table cells.
        for iconURL in [nil, directory.appendingPathComponent("missing.png"), imageURL] {
            for isEnabled in [true, false] {
                let project = ManagedProject(
                    id: UUID(), displayName: "Test App", folderPath: directory.path,
                    containerPath: directory.appendingPathComponent("Test.xcodeproj").path,
                    containerKind: .project, scheme: "Test", configuration: "Debug",
                    availableSchemes: ["Test"], availableConfigurations: ["Debug"],
                    isEnabled: isEnabled
                )
                let renderer = ImageRenderer(content: ProjectIconView(
                    project: project, iconURL: iconURL, size: 30, showsStatus: true
                ))
                let rendered = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(rendered.size, NSSize(width: 30, height: 30))
            }
        }
    }
}
