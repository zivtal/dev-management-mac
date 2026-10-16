import Foundation
import Security

enum MacStoreArchiveValidation {
    static func validate(archive: URL, bundleIdentifier: String, requirements: AppStoreArchiveRequirements? = nil) throws {
        let directory = archive.appendingPathComponent("Products/Applications")
        let applications = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let application = applications.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier }),
              let info = Bundle(url: application)?.infoDictionary else {
            throw AppStorePublishingError.missingArchiveApplication
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppStorePublishingError.distributionSigningUnavailable
        }
        var signature: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signature) == errSecSuccess,
              let values = signature as? [String: Any] else {
            throw AppStorePublishingError.distributionSigningUnavailable
        }
        try validate(info: info, entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:], requirements: requirements)
    }

    static func validate(info: [String: Any], entitlements: [String: Any], requirements: AppStoreArchiveRequirements? = nil) throws {
        if requirements?.networkClient == true, entitlements["com.apple.security.network.client"] as? Bool != true {
            throw AppStoreReleaseError.invalid("Mac archive is missing com.apple.security.network.client required for router/LAN access.")
        }
        let groups = entitlements["keychain-access-groups"] as? [String] ?? []
        for group in requirements?.keychainAccessGroups ?? [] where !groups.contains(group) {
            throw AppStoreReleaseError.invalid("Mac archive is missing required Keychain access group: \(group).")
        }
        if requirements?.encryptionDeclarationInInfoPlist == true, !(info["ITSAppUsesNonExemptEncryption"] is Bool) {
            throw AppStoreReleaseError.invalid("Mac Info.plist must explicitly declare ITSAppUsesNonExemptEncryption. Publishing does not infer or change the answer.")
        }
        guard entitlements["com.apple.security.app-sandbox"] as? Bool == true else {
            throw AppStoreConnectError.requestFailed(0, L10n.text("The Mac archive is not sandboxed. Select the Mac App Store scheme and enable App Sandbox before publishing."))
        }
        guard let category = info["LSApplicationCategoryType"] as? String,
              category.hasPrefix("public.app-category."), category.count > "public.app-category.".count else {
            throw AppStoreConnectError.requestFailed(0, L10n.text("Set the Mac app category in the selected scheme’s Info.plist before publishing."))
        }
    }
}
