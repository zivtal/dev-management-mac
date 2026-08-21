import AppKit

struct PerProjectWindowRegistry<Value: AnyObject> {
    private var values: [UUID: Value] = [:]

    var projectIDs: Set<UUID> {
        Set(values.keys)
    }

    subscript(projectID: UUID) -> Value? {
        values[projectID]
    }

    @discardableResult
    mutating func register(_ value: Value, for projectID: UUID) -> Value {
        precondition(values[projectID] == nil, "A window is already registered for this project.")
        values[projectID] = value
        return value
    }

    @discardableResult
    mutating func remove(projectID: UUID, matching value: Value) -> Value? {
        guard values[projectID] === value else { return nil }
        return values.removeValue(forKey: projectID)
    }
}

enum PerProjectWindowPlacement {
    static let cascadeStep: CGFloat = 28

    static func cascadedFrame(
        size: NSSize,
        in visibleFrame: NSRect,
        openWindowCount: Int
    ) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let horizontalRoom = max(0, visibleFrame.width - width)
        let verticalRoom = max(0, visibleFrame.height - height)
        let maximumOffset = min(horizontalRoom / 2, verticalRoom / 2)
        let offset = min(CGFloat(openWindowCount) * cascadeStep, maximumOffset)
        return NSRect(
            x: visibleFrame.midX - width / 2 + offset,
            y: visibleFrame.midY - height / 2 - offset,
            width: width,
            height: height
        )
    }
}
