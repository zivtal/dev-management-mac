import Foundation

/// Generated Info.plists do not exist in the source tree. Inspect the target's
/// build settings so companion apps still participate in screenshot preparation.
enum XcodeCompanionAppDiscovery {
    static func watchTargets(in data: Data, companionBundleIdentifier: String) -> [String] {
        guard let project = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
              let objects = project["objects"] as? [String: [String: Any]] else { return [] }

        return objects.values.compactMap { target -> String? in
            guard target["isa"] as? String == "PBXNativeTarget",
                  let productType = target["productType"] as? String,
                  productType.contains("application") || productType.contains("watchapp"),
                  let name = target["name"] as? String,
                  let listID = target["buildConfigurationList"] as? String,
                  let configurationIDs = objects[listID]?["buildConfigurations"] as? [String]
            else { return nil }

            let matches = configurationIDs.contains { id in
                guard let settings = objects[id]?["buildSettings"] as? [String: Any] else {
                    return false
                }
                let isWatch = (settings["SDKROOT"] as? String)?.hasPrefix("watch") == true
                    || productType.contains("watchapp")
                return isWatch && settings["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] as? String
                    == companionBundleIdentifier
            }
            return matches ? name : nil
        }.sorted()
    }
}
