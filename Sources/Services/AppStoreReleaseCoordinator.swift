import Foundation

struct AppStoreReleaseTarget: Sendable {
    let project: ManagedProject
    let configuration: PublishingConfiguration

    var label: String {
        "\(project.appStorePlatform.rawValue) / \(project.scheme) / \(project.marketingVersion ?? "?") (\(project.buildNumber ?? "?"))"
    }
}

enum AppStoreReleaseCoordinator {
    /// Resolve every target before the first upload. showBuildSettings never runs scheme actions.
    static func targets(project: ManagedProject, configuration: PublishingConfiguration,
                        runner: any ProcessRunning = ProcessRunner(),
                        validateReviewRequirements: Bool = true) async throws -> [AppStoreReleaseTarget] {
        let manifest = try AppStorePublishingManifest.load(from: project.folderURL)
        let entries = manifest?.platforms ?? [project.appStorePlatform.rawValue:
            AppStorePlatformReleaseConfiguration(scheme: project.scheme, configuration: archiveConfiguration(for: project))]
        let selected = configuration.selectedPlatforms.map { Set($0.map(\.rawValue)) }
            ?? Set(manifest?.defaultPlatforms ?? Array(entries.keys))
        guard !selected.isEmpty, selected.isSubset(of: Set(entries.keys)) else {
            throw AppStoreReleaseError.invalid("Select at least one configured release platform.")
        }
        var targets: [AppStoreReleaseTarget] = []
        for name in selected.sorted() {
            guard let platform = AppStorePlatform(rawValue: name), let entry = entries[name] else { continue }
            var target = project
            target.scheme = entry.scheme
            target.configuration = entry.configuration ?? "Release"
            target.applicationPlatform = platform == .macOS ? .macOS : .iOS
            target.companionWatch = nil
            target = try await resolve(project: target, platform: platform, runner: runner)
            var config = try configuration.applying(manifest?.publication(for: platform), validateReviewRequirements: validateReviewRequirements)
            config.archiveRequirements = entry.archiveRequirements
            // A platform override may authorize replacing its own review, never a sibling's.
            if platform != project.appStorePlatform { config.replaceActiveReviewVersion = false }
            targets.append(AppStoreReleaseTarget(project: target, configuration: config))
        }
        return targets
    }

    /// Explicit store configurations may carry a different bundle ID and sandbox entitlements.
    /// Only legacy, single-scheme projects need a Release default.
    static func archiveConfiguration(for project: ManagedProject) -> String {
        project.availableConfigurations.first { $0.caseInsensitiveCompare("Release") == .orderedSame }
            ?? project.configuration
    }

    static func screenshotProject(_ project: ManagedProject,
                                  runner: any ProcessRunning = ProcessRunner()) async throws -> ManagedProject {
        var preview = project
        preview.configuration = project.availableConfigurations.first {
            $0.caseInsensitiveCompare("Debug") == .orderedSame
        } ?? project.configuration
        return try await resolve(project: preview, platform: project.appStorePlatform, runner: runner)
    }

    static func resolve(project: ManagedProject, platform: AppStorePlatform,
                        runner: any ProcessRunning = ProcessRunner()) async throws -> ManagedProject {
        let response = try await runner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [project.containerKind.xcodebuildFlag, project.containerPath,
                        "-scheme", project.scheme, "-configuration", project.configuration,
                        "-destination", platform.destination, "-showBuildSettings", "-json"],
            workingDirectory: project.folderURL)
        return try resolvedProject(project, buildSettings: response.output, platform: platform)
    }

    static func resolvedProject(_ project: ManagedProject, buildSettings: String,
                                platform: AppStorePlatform) throws -> ManagedProject {
        let expected: ApplicationPlatform = platform == .macOS ? .macOS : .iOS
        guard let metadata = ProjectDiscoveryService.applicationMetadata(
            fromBuildSettingsJSON: buildSettings, expectedPlatform: expected),
              let bundle = metadata.bundleIdentifier,
              let settings = ProjectDiscoveryService.buildSettingsEntries(from: buildSettings)?
                .compactMap({ $0["buildSettings"] as? [String: Any] })
                .first(where: { $0["PRODUCT_BUNDLE_IDENTIFIER"] as? String == bundle }),
              let version = (settings["MARKETING_VERSION"] as? String)?.nilIfEmpty,
              let build = (settings["CURRENT_PROJECT_VERSION"] as? String)?.nilIfEmpty else {
            throw AppStoreReleaseError.invalid("\(platform.rawValue): scheme \(project.scheme) has no matching app target or resolved version/build. Regenerate the Xcode project if the scheme was recently added.")
        }
        var result = project
        result.bundleIdentifier = bundle
        result.marketingVersion = version
        result.buildNumber = build
        result.applicationPlatform = expected
        result.projectSigningTeamID = metadata.projectSigningTeamID
        result.supportedDeviceFamilies = metadata.supportedDeviceFamilies
        return result
    }

    static func run(_ targets: [AppStoreReleaseTarget],
                    output: @escaping @Sendable (String) -> Void,
                    publish: (AppStoreReleaseTarget) async throws -> PublishingResult) async throws -> PublishingResult {
        guard !targets.isEmpty else { throw AppStoreReleaseError.invalid("No release platforms configured.") }
        output("Release plan: " + targets.map(\.label).joined(separator: "; ") + "\n")
        var results: [PublishingResult] = []
        var summaries: [String] = []
        // Stop on failure: completed platforms remain recoverable via the exact-build checks.
        for target in targets {
            try Task.checkCancellation()
            output("Starting \(target.label)\n")
            do {
                results.append(try await publish(target))
                summaries.append(target.label)
                output("Completed \(target.label)\n")
            } catch {
                if error is CancellationError { throw error }
                let message = "Release failed for \(target.label): \(error.localizedDescription)\nCompleted platforms: \(summaries.isEmpty ? "none" : summaries.joined(separator: "; ")). Remaining platforms were not started."
                output(message + "\n")
                throw AppStoreReleaseError.invalid(message)
            }
        }
        let first = results[0]
        return PublishingResult(version: first.version, buildNumber: first.buildNumber, intent: first.intent,
            reusedExistingBuild: results.allSatisfy(\.reusedExistingBuild),
            deferredStorefrontSetup: results.contains(where: \.deferredStorefrontSetup), platformSummaries: summaries)
    }
}
