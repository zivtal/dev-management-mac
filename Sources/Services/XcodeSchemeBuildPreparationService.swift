import Foundation

struct PreparedXcodeScheme {
    let name: String
    let removedActionTitles: [String]
    let temporaryURL: URL?

    func removeTemporaryFile(fileManager: FileManager = .default) {
        guard let temporaryURL else { return }
        try? fileManager.removeItem(at: temporaryURL)
        TemporarySchemeRegistry.shared.release(temporaryURL)
    }
}

/// Tracks the temporary schemes this process is currently building with.
///
/// Installation and publishing run concurrently and are only serialised per managed
/// app, so two workflows can prepare schemes in one shared `xcshareddata/xcschemes`
/// directory — which happens whenever two managed apps are targets of the same Xcode
/// project. Without this, one workflow's residue sweep deletes the other's live scheme
/// and its build fails with "scheme not found".
final class TemporarySchemeRegistry: @unchecked Sendable {
    static let shared = TemporarySchemeRegistry()

    private let lock = NSLock()
    private var activePaths: Set<String> = []

    func reserve(_ url: URL) {
        lock.lock()
        activePaths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func release(_ url: URL) {
        lock.lock()
        activePaths.remove(url.standardizedFileURL.path)
        lock.unlock()
    }

    func isActive(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activePaths.contains(url.standardizedFileURL.path)
    }
}

enum XcodeSchemeBuildPreparationError: LocalizedError {
    case sharedSchemeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sharedSchemeNotFound(let scheme):
            L10n.format(
                "The shared Xcode scheme %@ could not be found, so its build actions could not be checked.",
                scheme
            )
        }
    }
}

final class XcodeSchemeBuildPreparationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Temporary schemes must live beside the original so `xcodebuild -scheme` can
    /// find them inside the container, which means a crash can leave one behind in
    /// the managed repository. Sweeping on entry keeps that residue from accumulating.
    static let temporarySchemePrefix = "DevelopmentManagement-"

    func prepare(project: ManagedProject) throws -> PreparedXcodeScheme {
        guard let sourceURL = sharedSchemeURL(for: project) else {
            throw XcodeSchemeBuildPreparationError.sharedSchemeNotFound(project.scheme)
        }
        removeStaleTemporarySchemes(in: sourceURL.deletingLastPathComponent())
        let document = try XMLDocument(contentsOf: sourceURL, options: [.nodePreserveAll])
        let executionActions = try document.nodes(forXPath: "//ExecutionAction")
            .compactMap { $0 as? XMLElement }
        var removedTitles: [String] = []

        for action in executionActions {
            guard let content = action.elements(forName: "ActionContent").first else { continue }
            let title = content.attribute(forName: "title")?.stringValue?.nilIfEmpty
                ?? L10n.text("Scheme script")
            removedTitles.append(title)
            action.detach()
        }

        guard !removedTitles.isEmpty else {
            return PreparedXcodeScheme(
                name: project.scheme,
                removedActionTitles: [],
                temporaryURL: nil
            )
        }

        for containerName in ["PreActions", "PostActions"] {
            for case let container as XMLElement in try document.nodes(forXPath: "//\(containerName)")
            where container.elements(forName: "ExecutionAction").isEmpty {
                container.detach()
            }
        }

        let safeBaseName = project.scheme.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let preparedName = "\(Self.temporarySchemePrefix)\(safeBaseName)-\(UUID().uuidString)"
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(preparedName).xcscheme")
        // Reserved before it exists, so a concurrent prepare can never observe the
        // file without also seeing that it is in use.
        TemporarySchemeRegistry.shared.reserve(temporaryURL)
        do {
            try document.xmlData(options: [.nodePrettyPrint]).write(to: temporaryURL, options: .atomic)
        } catch {
            TemporarySchemeRegistry.shared.release(temporaryURL)
            throw error
        }
        return PreparedXcodeScheme(
            name: preparedName,
            removedActionTitles: removedTitles,
            temporaryURL: temporaryURL
        )
    }

    /// When this process launched. Anything older was left behind by an earlier one,
    /// because a scheme prepared by this process is either still registered or already
    /// deleted by its `defer`. Read from the kernel rather than captured lazily, so it
    /// does not depend on when this type was first touched.
    static let processStartDate: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return Date()
        }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec)
                + Double(started.tv_usec) / 1_000_000
        )
    }()

    /// Removes leftover temporary schemes from earlier runs that were interrupted
    /// before their `defer` cleanup could run. Only files this service names are
    /// eligible, so a repository's own schemes are never touched, and only files that
    /// predate this process and belong to no in-flight build.
    private func removeStaleTemporarySchemes(in directory: URL) {
        let candidates = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for candidate in candidates where Self.isTemporaryScheme(candidate) {
            guard !TemporarySchemeRegistry.shared.isActive(candidate) else { continue }
            guard Self.isResidue(
                candidate,
                processStartDate: Self.processStartDate,
                fileManager: fileManager
            ) else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    /// A temporary scheme older than this process, and therefore abandoned.
    static func isResidue(
        _ url: URL,
        processStartDate: Date,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date
        else {
            // An unreadable timestamp is treated as in-flight: leaving residue behind
            // is recoverable, deleting a live scheme is not.
            return false
        }
        return modified < processStartDate
    }

    static func isTemporaryScheme(_ url: URL) -> Bool {
        url.pathExtension == "xcscheme"
            && url.lastPathComponent.hasPrefix(temporarySchemePrefix)
    }

    private func sharedSchemeURL(for project: ManagedProject) -> URL? {
        let directURL = project.containerURL
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
            .appendingPathComponent("\(project.scheme).xcscheme")
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = fileManager.enumerator(
            at: project.folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let expectedName = "\(project.scheme).xcscheme"
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == expectedName,
                  candidate.path.contains("/xcshareddata/xcschemes/") else { continue }
            return candidate
        }
        return nil
    }
}
