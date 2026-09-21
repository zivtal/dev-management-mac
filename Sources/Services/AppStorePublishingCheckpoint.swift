import CryptoKit
import Foundation

/// A release's binary is immutable, just like the same version/build in TestFlight.
/// Only successful steps are recorded. Credentials are never stored here.
final class AppStorePublishingCheckpoint {
    struct Identity: Codable, Equatable {
        let projectPath: String
        let containerPath: String
        let scheme: String
        let configuration: String
        let teamID: String?
        let issuerID: String
        let appID: String
        let bundleIdentifier: String
        let version: String
        let buildNumber: String

        init(project: ManagedProject, issuerID: String, appID: String) throws {
            guard let bundle = project.bundleIdentifier,
                  let version = project.marketingVersion,
                  let build = project.buildNumber else {
                throw AppStorePublishingError.missingVersion
            }
            projectPath = project.folderURL.standardizedFileURL.path
            containerPath = project.containerURL.standardizedFileURL.path
            scheme = project.scheme
            configuration = project.configuration
            teamID = project.signingTeamID ?? project.projectSigningTeamID
            self.issuerID = issuerID
            self.appID = appID
            bundleIdentifier = bundle
            self.version = version
            buildNumber = build
        }
    }

    private struct Record: Codable {
        let identity: Identity
        var archived = false
        var ipaFilename: String?
        var ipaSHA256: String?
        var validatedSHA256: String?
        var uploadAccepted = false
    }

    let directory: URL
    let identity: Identity
    private let fileManager: FileManager
    private var record: Record
    var archiveURL: URL { directory.appendingPathComponent("Application.xcarchive") }
    var exportURL: URL { directory.appendingPathComponent("Export", isDirectory: true) }
    private var recordURL: URL { directory.appendingPathComponent("checkpoint.json") }
    var uploadAccepted: Bool { record.uploadAccepted }

    init(identity: Identity, root: URL? = nil, fileManager: FileManager = .default) throws {
        self.identity = identity
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        let root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevManagement/PublishingArtifacts", isDirectory: true)
        directory = root.appendingPathComponent(digest, isDirectory: true)
        let recordURL = directory.appendingPathComponent("checkpoint.json")
        if let data = try? Data(contentsOf: recordURL),
           let saved = try? JSONDecoder().decode(Record.self, from: data),
           saved.identity == identity {
            record = saved
        } else {
            record = Record(identity: identity)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    var hasArchive: Bool {
        guard record.archived,
              let metadata = try? AppStorePublishingService.archiveMetadata(
                at: archiveURL, expectedBundleIdentifier: identity.bundleIdentifier,
                fileManager: fileManager
              ) else { return false }
        return metadata.version == identity.version && metadata.buildNumber == identity.buildNumber
    }

    func markArchived() throws {
        let metadata = try AppStorePublishingService.archiveMetadata(
            at: archiveURL, expectedBundleIdentifier: identity.bundleIdentifier,
            fileManager: fileManager
        )
        guard metadata.version == identity.version else {
            throw AppStorePublishingError.archiveVersionMismatch(expected: identity.version, actual: metadata.version)
        }
        guard metadata.buildNumber == identity.buildNumber else {
            throw AppStorePublishingError.archiveBuildNumberMismatch(expected: identity.buildNumber, actual: metadata.buildNumber)
        }
        record.archived = true
        try save()
    }

    func artifact() throws -> AppStoreBuildArtifact? {
        guard let filename = record.ipaFilename, filename == URL(fileURLWithPath: filename).lastPathComponent,
              let expectedHash = record.ipaSHA256 else { return nil }
        let ipaURL = exportURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: ipaURL.path),
              try Self.checksum(ipaURL) == expectedHash else { return nil }
        return AppStoreBuildArtifact(ipaURL: ipaURL, archiveURL: archiveURL,
                                    bundleIdentifier: identity.bundleIdentifier,
                                    version: identity.version, buildNumber: identity.buildNumber)
    }

    func markExported(ipaURL: URL) throws {
        precondition(ipaURL.deletingLastPathComponent().standardizedFileURL == exportURL.standardizedFileURL)
        record.ipaFilename = ipaURL.lastPathComponent
        record.ipaSHA256 = try Self.checksum(ipaURL)
        record.validatedSHA256 = nil
        try save()
    }

    var isValidated: Bool {
        record.ipaSHA256 != nil && record.validatedSHA256 == record.ipaSHA256
    }

    func markValidated() throws {
        record.validatedSHA256 = record.ipaSHA256
        try save()
    }

    func markUploadAccepted() throws {
        record.uploadAccepted = true
        try save()
    }

    /// Remove incomplete outputs before rerunning a stage; never reuse a partial export.
    func prepareArchive() throws {
        record.archived = false
        try prepareExport()
        if fileManager.fileExists(atPath: archiveURL.path) { try fileManager.removeItem(at: archiveURL) }
    }

    func prepareExport() throws {
        record.ipaFilename = nil
        record.ipaSHA256 = nil
        record.validatedSHA256 = nil
        try save()
        if fileManager.fileExists(atPath: exportURL.path) { try fileManager.removeItem(at: exportURL) }
    }

    /// After the full pipeline succeeds, Apple's build is the durable copy.
    /// Keep the upload receipt so propagation delays cannot cause a duplicate upload.
    func removeCompletedArtifacts() {
        try? fileManager.removeItem(at: archiveURL)
        try? fileManager.removeItem(at: exportURL)
    }

    private func save() throws {
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    private static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
