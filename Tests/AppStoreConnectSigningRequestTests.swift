import CryptoKit
import XCTest
@testable import DevManagement

/// Captures the requests a service actually puts on the wire and replays canned
/// responses, so query parameters and request bodies are asserted as sent rather than
/// as intended.
final class StubURLProtocol: URLProtocol {
    struct Exchange: @unchecked Sendable {
        let match: (URLRequest) -> Bool
        let statusCode: Int
        let body: [String: Any]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [Exchange] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data] = []

    static func reset() {
        lock.lock()
        exchanges = []
        captured = []
        capturedBodies = []
        lock.unlock()
    }

    static func enqueue(_ exchange: Exchange) {
        lock.lock()
        exchanges.append(exchange)
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody, so the stream is drained to recover it.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }

        Self.lock.lock()
        Self.captured.append(request)
        Self.capturedBodies.append(body ?? Data())
        let exchange = Self.exchanges.first { $0.match(request) }
        Self.lock.unlock()

        let statusCode = exchange?.statusCode ?? 200
        let payload = exchange?.body ?? ["data": []]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppStoreConnectSigningRequestTests: XCTestCase {
    private func makeService() throws -> AppStoreConnectService {
        try AppStoreConnectService(
            issuerID: "issuer",
            keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: StubURLProtocol.session()
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private static func queryItems(_ request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return [:]
        }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// App Store Connect only returns a relationship's `data` linkage for
    /// relationships named in `include`. Asking for `certificates` as a field is not
    /// enough, and without the linkage every profile looks like it authorizes nothing.
    func testProfilesRequestIncludesTheCertificatesRelationship() async throws {
        let service = try makeService()

        _ = try await service.profiles()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/profiles")
        let query = Self.queryItems(request)
        let included = Set((query["include"] ?? "").split(separator: ",").map(String.init))
        XCTAssertEqual(included, ["bundleId", "certificates"])
        XCTAssertEqual(query["fields[certificates]"], "certificateType")
        XCTAssertEqual(query["fields[bundleIds]"], "identifier")
        XCTAssertTrue(query["fields[profiles]"]?.contains("profileContent") == true)
    }

    func testProfilesDecodeCertificateLinkageFromAnIncludedResponse() async throws {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/profiles" },
            statusCode: 200,
            body: [
                "data": [[
                    "type": "profiles",
                    "id": "PROFILE1",
                    "attributes": [
                        "name": "Store Profile",
                        "profileType": "IOS_APP_STORE",
                        "profileState": "ACTIVE",
                        "uuid": "1111-2222",
                        "profileContent": Data("profile".utf8).base64EncodedString(),
                        "expirationDate": "2027-08-15T17:37:13.000+00:00"
                    ],
                    "relationships": [
                        "bundleId": ["data": ["type": "bundleIds", "id": "B1"]],
                        "certificates": ["data": [["type": "certificates", "id": "CERT1"]]]
                    ]
                ]],
                "included": [[
                    "type": "bundleIds",
                    "id": "B1",
                    "attributes": ["identifier": "com.example.app"]
                ]]
            ]
        ))
        let service = try makeService()

        let profiles = try await service.profiles()

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.certificateIDs, ["CERT1"])
        XCTAssertEqual(profile.bundleIdentifier, "com.example.app")
        XCTAssertNotNil(profile.profileContent)
        // The reuse path is only reachable because the linkage decoded.
        XCTAssertEqual(
            AppStoreProvisioningProfileService.reusableAccountProfile(
                in: profiles,
                bundleIdentifier: "com.example.app",
                certificateID: "CERT1"
            )?.id,
            "PROFILE1"
        )
    }

    /// A profile whose relationship linkage is absent — the shape the API returns when
    /// `include` is missing — must never be treated as reusable.
    func testProfileWithoutCertificateLinkageIsNotReusable() async throws {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/profiles" },
            statusCode: 200,
            body: [
                "data": [[
                    "type": "profiles",
                    "id": "PROFILE1",
                    "attributes": [
                        "name": "Store Profile",
                        "profileType": "IOS_APP_STORE",
                        "profileState": "ACTIVE",
                        "profileContent": Data("profile".utf8).base64EncodedString()
                    ],
                    "relationships": [
                        "certificates": ["links": ["related": "https://example.invalid"]]
                    ]
                ]]
            ]
        ))
        let service = try makeService()

        let profiles = try await service.profiles()

        XCTAssertEqual(profiles.first?.certificateIDs, [])
        XCTAssertNil(AppStoreProvisioningProfileService.reusableAccountProfile(
            in: profiles,
            bundleIdentifier: "com.example.app",
            certificateID: "CERT1"
        ))
    }

    func testCreateIOSBundleIDPostsAnExactIdentifier() async throws {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/bundleIds" && $0.httpMethod == "POST" },
            statusCode: 201,
            body: [
                "data": [
                    "type": "bundleIds",
                    "id": "B9",
                    "attributes": ["identifier": "com.example.app.widget", "name": "Widget"]
                ]
            ]
        ))
        let service = try makeService()

        let created = try await service.createIOSBundleID(
            identifier: "com.example.app.widget",
            name: "Widget"
        )

        XCTAssertEqual(created, AppStoreConnectBundleID(
            id: "B9",
            identifier: "com.example.app.widget",
            name: "Widget"
        ))
        let body = try XCTUnwrap(StubURLProtocol.bodies.first)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "bundleIds")
        let attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["identifier"] as? String, "com.example.app.widget")
        XCTAssertEqual(attributes["platform"] as? String, "IOS")
        XCTAssertFalse(
            (attributes["identifier"] as? String)?.contains("*") == true,
            "a wildcard identifier can never back an App Store profile"
        )
    }

    func testCertificateCreationDoesNotHideAFollowUpFetchBehindThePOST() async throws {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "POST" },
            statusCode: 201,
            body: [
                "data": [
                    "type": "certificates",
                    "id": "CERT-ISSUED",
                    "attributes": [
                        "certificateType": "DISTRIBUTION",
                        "displayName": "Apple Distribution: Example"
                    ]
                ]
            ]
        ))
        let service = try makeService()

        let issued = try await service.createDistributionCertificate(csrContent: "CSR")

        XCTAssertEqual(issued.id, "CERT-ISSUED")
        XCTAssertNil(issued.certificateContent)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.first?.httpMethod, "POST")
        // The provisioning layer records CERT-ISSUED beside the pending private key
        // before it is allowed to perform a separate details request.
    }

    func testRevokeCertificateIssuesADeleteForThatCertificateOnly() async throws {
        let service = try makeService()

        try await service.revokeCertificate(id: "CERT7")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/certificates/CERT7")
    }

    func testBundleIDCreateBodyIsSerializable() throws {
        let body = AppStoreConnectService.bundleIDCreateBody(
            identifier: "com.example.app",
            name: "Example"
        )

        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
}
