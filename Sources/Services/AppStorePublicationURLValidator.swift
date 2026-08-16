import Foundation

struct AppStorePublicationURL: Equatable, Sendable {
    let label: String
    let url: URL
}

enum AppStorePublicationURLValidationError: LocalizedError {
    case unreachable(String, String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let label, let reason):
            L10n.format("The %@ URL is not publicly reachable: %@", label, reason)
        }
    }
}

final class AppStorePublicationURLValidator {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func publicationURLs(configuration: PublishingConfiguration) -> [AppStorePublicationURL] {
        let values: [(String, String?)] = [
            (L10n.text("support"), configuration.supportURL),
            (L10n.text("marketing"), configuration.marketingURL),
            (L10n.text("Terms of Use"), configuration.termsURL),
            (L10n.text("privacy policy"), configuration.privacyPolicyURL),
            (L10n.text("privacy choices"), configuration.privacyChoicesURL)
        ]
        var seen = Set<String>()
        return values.compactMap { label, rawValue in
            guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty,
                  let url = URL(string: rawValue),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil,
                  seen.insert(url.absoluteString).inserted else { return nil }
            return AppStorePublicationURL(label: label, url: url)
        }
    }

    func validate(_ values: [AppStorePublicationURL]) async throws {
        for value in values {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: value.url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 20
                var (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<400).contains(http.statusCode) {
                    request.httpMethod = "GET"
                    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                    (_, response) = try await session.data(for: request)
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw AppStorePublicationURLValidationError.unreachable(
                        value.label,
                        L10n.format("%@ returned HTTP %d.", value.url.absoluteString, status)
                    )
                }
            } catch let error as AppStorePublicationURLValidationError {
                throw error
            } catch {
                throw AppStorePublicationURLValidationError.unreachable(
                    value.label,
                    "\(value.url.absoluteString) (\(error.localizedDescription))"
                )
            }
        }
    }
}
