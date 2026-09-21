import Foundation

extension AppStoreConnectService {
    /// Compare only fields owned by this update. Missing remote fields are not
    /// assumed to match, and state-changing review/upload actions do not use this.
    func updateResourceIfNeeded(
        path: String,
        body: [String: Any],
        existing: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let current: [String: Any]
        if let existing {
            current = existing
        } else {
            let response = try await request(method: "GET", path: path)
            guard let resource = response["data"] as? [String: Any] else {
                throw AppStoreConnectError.invalidResponse
            }
            current = resource
        }
        if let desired = body["data"] as? [String: Any], Self.resource(current, matches: desired) {
            return ["data": current]
        }
        return try await request(method: "PATCH", path: path, body: body)
    }

    static func resource(_ current: [String: Any], matches desired: [String: Any]) -> Bool {
        desired.allSatisfy { key, value in
            guard let existing = current[key] else { return false }
            if let nested = value as? [String: Any], let existing = existing as? [String: Any] {
                return resource(existing, matches: nested)
            }
            return (value as? NSObject)?.isEqual(existing) == true
        }
    }
}
