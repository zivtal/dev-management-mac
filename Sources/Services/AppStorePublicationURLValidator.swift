import Foundation

struct AppStorePublicationURL: Equatable, Sendable {
    let label: String
    let url: URL
}

enum AppStorePublicationURLValidationError: LocalizedError {
    case httpFailure(label: String, url: URL, statusCode: Int)
    case connectionFailure(label: String, url: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .httpFailure(let label, let url, let statusCode):
            L10n.format(
                "The %@ URL returned HTTP %d: %@. Update it to a public page that returns HTTP 200–399, then try again.",
                label,
                statusCode,
                url.absoluteString
            )
        case .connectionFailure(let label, let url, let reason):
            L10n.format(
                "The %@ URL could not be reached: %@ (%@). Check the URL and internet connection, then try again.",
                label,
                url.absoluteString,
                reason
            )
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
                    (_, response) = try await session.data(for: request)
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw AppStorePublicationURLValidationError.httpFailure(
                        label: value.label,
                        url: value.url,
                        statusCode: status
                    )
                }
            } catch let error as AppStorePublicationURLValidationError {
                throw error
            } catch {
                throw AppStorePublicationURLValidationError.connectionFailure(
                    label: value.label,
                    url: value.url,
                    reason: error.localizedDescription
                )
            }
        }
    }
}
