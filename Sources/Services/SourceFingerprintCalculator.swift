import CryptoKit
import Foundation

/// Content fingerprint of a project's watched sources, mirroring
/// run-emulator.sh's shasum pipeline. Rewrites that leave content identical —
/// like the XcodeGen regeneration a build performs — keep the fingerprint
/// stable, so the session's own build never retriggers itself.
enum SourceFingerprintCalculator {
    static func fingerprint(of rootURL: URL, fileManager: FileManager = .default) -> String {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        var fileHashes: [(path: String, digest: String)] = []
        for case let url as URL in enumerator {
            let path = url.path
            if SourceChangeWatcher.shouldIgnore(path: path) {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent.hasPrefix(
                    XcodeSchemeBuildPreparationService.temporarySchemePrefix
                  ) == false,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                continue
            }
            fileHashes.append((
                path: path,
                digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }

        var combined = SHA256()
        for file in fileHashes.sorted(by: { $0.path < $1.path }) {
            combined.update(data: Data("\(file.digest)  \(file.path)\n".utf8))
        }
        return combined.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
