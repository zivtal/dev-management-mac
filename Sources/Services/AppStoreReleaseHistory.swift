import CryptoKit
import Foundation

/// A receipt is written only after the platform has completed the requested release action.
/// Version files can be omitted from sourcePaths when platforms share a version counter.
struct AppStoreReleaseHistory {
    struct Fingerprint: Codable, Equatable {
        let sources: String
        let publication: String
    }
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevManagement/ReleaseHistory")
    }
    func fingerprint(project: ManagedProject, manifest: AppStorePublishingManifest?) throws -> Fingerprint {
        let paths = manifest?.platforms?[project.appStorePlatform.rawValue]?.sourcePaths
        var files: [URL] = []
        let base = project.folderURL.standardizedFileURL
        for path in paths ?? ["."] {
            let url = base.appendingPathComponent(path).standardizedFileURL
            guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
                throw AppStoreReleaseError.invalid("Release sourcePaths must stay inside the project: \(path)")
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
                // A deleted input must also change the fingerprint.
                continue
            }
            if !directory.boolValue { files.append(url); continue }
            guard let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                throw AppStoreReleaseError.invalid("Cannot inspect release sources: \(path)")
            }
            for case let file as URL in enumerator {
                if SourceChangeWatcher.shouldIgnore(path: file.path) || ["xcodeproj", "xcworkspace"].contains(file.pathExtension) {
                    enumerator.skipDescendants(); continue
                }
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                   !["app-store-publishing.json", ".app-store-publishing.json"].contains(file.lastPathComponent) {
                    files.append(file)
                }
            }
        }
        var hash = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let entry = manifest?.platforms?[project.appStorePlatform.rawValue]
        hash.update(data: try encoder.encode(entry?.archiveRequirements))
        hash.update(data: Data((project.scheme + "|" + (entry?.configuration ?? project.configuration)).utf8))
        for file in Set(files).sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.replacingOccurrences(of: base.path + "/", with: "").utf8))
            hash.update(data: Data([0]))
            hash.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        let publication = try manifest?.publication(for: project.appStorePlatform)
        // App-wide declarations/subscriptions also affect each selected platform. Privacy publication
        // timestamps are operational receipts and must not mark every platform changed.
        let payload = try encoder.encode(AppStorePublishingManifest(schemaVersion: 1,
            publication: publication, application: manifest?.application, subscriptions: manifest?.subscriptions))
        return Fingerprint(sources: Self.hex(hash.finalize()), publication: Self.hex(SHA256.hash(data: payload)))
    }
    func previous(project: ManagedProject, intent: PublishingIntent) throws -> Fingerprint? {
        let url = receiptURL(project: project, intent: intent)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Fingerprint.self, from: Data(contentsOf: url))
    }
    func save(_ fingerprint: Fingerprint, project: ManagedProject, intent: PublishingIntent) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(fingerprint).write(to: receiptURL(project: project, intent: intent), options: .atomic)
    }
    private func receiptURL(project: ManagedProject, intent: PublishingIntent) -> URL {
        let key = "\(project.folderPath)|\(project.scheme)|\(project.appStorePlatform.rawValue)|\(intent == .publish ? "publish" : "testflight")"
        return root.appendingPathComponent(Self.hex(SHA256.hash(data: Data(key.utf8))) + ".json")
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
