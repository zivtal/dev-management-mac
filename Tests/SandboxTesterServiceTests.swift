import CryptoKit
import XCTest
@testable import DevManagement

final class SandboxTesterServiceTests: XCTestCase {
    override func tearDown() {
        SandboxTesterURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchSandboxTestersDecodesAndSortsAccounts() async throws {
        SandboxTesterURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v2/sandboxTesters")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "limit" })?.value,
                "200"
            )
            return try Self.response(
                for: request,
                status: 200,
                json: [
                    "data": [
                        Self.testerResource(
                            id: "second",
                            accountName: "zeta@example.com",
                            firstName: "Zeta"
                        ),
                        Self.testerResource(
                            id: "first",
                            accountName: "alpha@example.com",
                            firstName: "Alpha"
                        )
                    ],
                    "links": ["self": request.url?.absoluteString ?? ""]
                ]
            )
        }

        let testers = try await makeService().fetchSandboxTesters()

        XCTAssertEqual(testers.map(\.id), ["first", "second"])
        XCTAssertEqual(testers.first?.displayName, "Alpha Tester")
        XCTAssertEqual(testers.first?.territory, "ISR")
        XCTAssertEqual(testers.first?.subscriptionRenewalDescription, L10n.text("Every 5 minutes"))
    }

    func testClearSandboxPurchaseHistoryUsesAppleBatchEndpoint() async throws {
        SandboxTesterURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/v2/sandboxTestersClearPurchaseHistoryRequest"
            )
            return try Self.response(
                for: request,
                status: 201,
                json: [
                    "data": [
                        "type": "sandboxTestersClearPurchaseHistoryRequest",
                        "id": "reset-request"
                    ]
                ]
            )
        }

        try await makeService().clearSandboxPurchaseHistory(
            testerIDs: ["tester-b", "tester-a", "tester-b"]
        )
    }

    func testClearSandboxPurchaseHistoryBuildsAppleBatchRelationship() throws {
        let body = AppStoreConnectService.sandboxPurchaseHistoryRequestBody(
            testerIDs: ["tester-a", "tester-b"]
        )
        let data = try XCTUnwrap(body["data"] as? [String: Any])
        XCTAssertEqual(
            data["type"] as? String,
            "sandboxTestersClearPurchaseHistoryRequest"
        )
        let relationships = try XCTUnwrap(data["relationships"] as? [String: Any])
        let sandboxTesters = try XCTUnwrap(
            relationships["sandboxTesters"] as? [String: Any]
        )
        let references = try XCTUnwrap(sandboxTesters["data"] as? [[String: String]])
        XCTAssertEqual(
            references,
            [
                ["type": "sandboxTesters", "id": "tester-a"],
                ["type": "sandboxTesters", "id": "tester-b"]
            ]
        )
    }

    func testSandboxTesterFallsBackToAccountNameForMissingPersonName() throws {
        let tester = try XCTUnwrap(AppStoreConnectService.sandboxTester(
            Self.testerResource(
                id: "tester",
                accountName: "sandbox@example.com",
                firstName: "",
                lastName: ""
            )
        ))

        XCTAssertEqual(tester.displayName, "sandbox@example.com")
    }

    private func makeService() throws -> AppStoreConnectService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SandboxTesterURLProtocol.self]
        return try AppStoreConnectService(
            issuerID: "issuer",
            keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: URLSession(configuration: configuration)
        )
    }

    private static func testerResource(
        id: String,
        accountName: String,
        firstName: String,
        lastName: String = "Tester"
    ) -> [String: Any] {
        [
            "type": "sandboxTesters",
            "id": id,
            "attributes": [
                "acAccountName": accountName,
                "firstName": firstName,
                "lastName": lastName,
                "territory": "ISR",
                "interruptPurchases": false,
                "subscriptionRenewalRate": "MONTHLY_RENEWAL_EVERY_FIVE_MINUTES"
            ]
        ]
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        json: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, try JSONSerialization.data(withJSONObject: json))
    }
}

private final class SandboxTesterURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
