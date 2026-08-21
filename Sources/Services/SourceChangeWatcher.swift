import CoreServices
import Foundation

/// Watches a project folder with FSEvents and reports debounced source
/// changes, mirroring run-emulator.sh's fingerprint loop natively.
final class SourceChangeWatcher {
    typealias ChangeHandler = @Sendable () -> Void

    private static let ignoredDirectoryNames: Set<String> = [
        ".git", "DerivedData", "xcuserdata", ".build", ".swiftpm", "dist", "node_modules"
    ]
    private static let ignoredFileNames: Set<String> = [".DS_Store"]
    private static let ignoredFileExtensions: Set<String> = ["md"]

    private let queue = DispatchQueue(label: "com.zivtal.DevManagement.SourceChangeWatcher")
    private let debounceInterval: TimeInterval
    private let onChange: ChangeHandler
    private var stream: FSEventStreamRef?
    private var pendingChange: DispatchWorkItem?

    init?(
        directoryURL: URL,
        debounceInterval: TimeInterval = 0.5,
        onChange: @escaping ChangeHandler
    ) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SourceChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                watcher.scheduleChange()
                return
            }
            let relevantPaths = paths.prefix(Int(eventCount)).filter {
                !SourceChangeWatcher.shouldIgnore(path: $0)
            }
            if !relevantPaths.isEmpty {
                watcher.scheduleChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directoryURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        stop()
    }

    func stop() {
        queue.sync {
            pendingChange?.cancel()
            pendingChange = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    static func shouldIgnore(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        if ignoredFileNames.contains(fileName) { return true }
        if ignoredFileExtensions.contains(url.pathExtension.lowercased()) { return true }
        return url.pathComponents.contains { ignoredDirectoryNames.contains($0) }
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let workItem = DispatchWorkItem { [onChange] in onChange() }
        pendingChange = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
