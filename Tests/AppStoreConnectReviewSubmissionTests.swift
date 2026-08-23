import CryptoKit
import XCTest
@testable import DevManagement

final class AppStoreConnectReviewSubmissionTests: XCTestCase {
    override func tearDown() {
        ReviewSubmissionURLProtocolStub.reset()
        super.tearDown()
    }

    func testReviewConflictReportsNestedAssociatedErrorsInsteadOfWrapper() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "errors": [[
                "detail": "This resource cannot be reviewed, please check associated errors to see why.",
                "meta": [
                    "associatedErrors": [
                        "subscriptions": [[
                            "detail": "Create a new subscription version after withdrawing the previous submission."
                        ]],
                        "version": [[
                            "title": "The App Store version is missing required review information."
                        ]]
                    ]
                ]
            ]]
        ])

        XCTAssertEqual(
            AppStoreConnectService.errorMessage(from: data),
            "Create a new subscription version after withdrawing the previous submission.\nThe App Store version is missing required review information."
        )
    }

    func testUnresolvedSubmissionOwningVersionIsResolvedAndResubmitted() async throws {
        var canceledEmptyDraft = false
        var resolvedVersionItem = false
        var submittedOwningSubmission = false
        let service = try makeService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/reviewSubmissions"):
                return try Self.response(for: request, status: 200, json: [
                    "data": [
                        Self.submission(id: "empty-draft", state: "READY_FOR_REVIEW"),
                        Self.submission(id: "owning-submission", state: "UNRESOLVED_ISSUES")
                    ]
                ])
            case ("GET", "/v1/reviewSubmissions/empty-draft/items"):
                return try Self.response(for: request, status: 200, json: ["data": []])
            case ("GET", "/v1/reviewSubmissions/owning-submission/items"):
                return try Self.response(for: request, status: 200, json: [
                    "data": [
                        Self.item(
                            id: "version-item",
                            state: "REJECTED",
                            relationship: "appStoreVersion",
                            type: "appStoreVersions",
                            relatedID: "version-id"
                        ),
                        Self.item(
                            id: "subscription-item",
                            state: "READY_FOR_REVIEW",
                            relationship: "subscriptionVersion",
                            type: "subscriptionVersions",
                            relatedID: "subscription-version-id"
                        )
                    ]
                ])
            case ("PATCH", "/v1/reviewSubmissions/empty-draft"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["canceled"] as? Bool,
                    true
                )
                canceledEmptyDraft = true
                return try Self.response(for: request, status: 200, json: [
                    "data": Self.submission(id: "empty-draft", state: "CANCELING")
                ])
            case ("PATCH", "/v1/reviewSubmissionItems/version-item"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["resolved"] as? Bool,
                    true
                )
                resolvedVersionItem = true
                return try Self.response(for: request, status: 200, json: [
                    "data": Self.item(
                        id: "version-item",
                        state: "READY_FOR_REVIEW",
                        relationship: "appStoreVersion",
                        type: "appStoreVersions",
                        relatedID: "version-id"
                    )
                ])
            case ("PATCH", "/v1/reviewSubmissions/owning-submission"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["submitted"] as? Bool,
                    true
                )
                submittedOwningSubmission = true
                return try Self.response(for: request, status: 200, json: [
                    "data": Self.submission(id: "owning-submission", state: "WAITING_FOR_REVIEW")
                ])
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.response(for: request, status: 500, json: [:])
            }
        }

        try await service.submitForReview(
            appID: "app-id",
            versionID: "version-id",
            additionalItems: [
                AppStoreConnectReviewItem(
                    relationship: "subscriptionVersion",
                    resourceType: "subscriptionVersions",
                    id: "subscription-version-id",
                    label: "Premium"
                )
            ],
            intent: .publish
        )

        XCTAssertTrue(canceledEmptyDraft)
        XCTAssertTrue(resolvedVersionItem)
        XCTAssertTrue(submittedOwningSubmission)
        XCTAssertFalse(ReviewSubmissionURLProtocolStub.requests.contains {
            $0.httpMethod == "POST"
        })
    }

    func testUnverifiedItemConflictIsNotTreatedAsAlreadyAttached() async throws {
        let service = try makeService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/reviewSubmissions"):
                return try Self.response(for: request, status: 200, json: [
                    "data": [Self.submission(id: "draft-id", state: "READY_FOR_REVIEW")]
                ])
            case ("GET", "/v1/reviewSubmissions/draft-id/items"):
                return try Self.response(for: request, status: 200, json: ["data": []])
            case ("POST", "/v1/reviewSubmissionItems"):
                return try Self.response(for: request, status: 409, json: [
                    "errors": [["detail": "The app version belongs to another submission."]]
                ])
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.response(for: request, status: 500, json: [:])
            }
        }

        do {
            try await service.submitForReview(
                appID: "app-id",
                versionID: "version-id",
                intent: .publish
            )
            XCTFail("Expected the unattached-item conflict to be preserved")
        } catch AppStoreConnectError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "The app version belongs to another submission.")
        }

        XCTAssertFalse(ReviewSubmissionURLProtocolStub.requests.contains { request in
            guard request.httpMethod == "PATCH" else { return false }
            return request.url?.path == "/v1/reviewSubmissions/draft-id"
        })
    }

    func testReadyDraftResolvesAttachedRejectedItemBeforeSubmission() async throws {
        var resolvedSubscriptionItem = false
        var submitted = false
        let service = try makeService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/reviewSubmissions"):
                return try Self.response(for: request, status: 200, json: [
                    "data": [Self.submission(id: "draft-id", state: "READY_FOR_REVIEW")]
                ])
            case ("GET", "/v1/reviewSubmissions/draft-id/items"):
                return try Self.response(for: request, status: 200, json: [
                    "data": [
                        Self.item(
                            id: "version-item",
                            state: "READY_FOR_REVIEW",
                            relationship: "appStoreVersion",
                            type: "appStoreVersions",
                            relatedID: "version-id"
                        ),
                        Self.item(
                            id: "subscription-item",
                            state: "REJECTED",
                            relationship: "subscriptionVersion",
                            type: "subscriptionVersions",
                            relatedID: "subscription-version-id"
                        )
                    ]
                ])
            case ("PATCH", "/v1/reviewSubmissionItems/subscription-item"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["resolved"] as? Bool,
                    true
                )
                resolvedSubscriptionItem = true
                return try Self.response(for: request, status: 200, json: [:])
            case ("PATCH", "/v1/reviewSubmissions/draft-id"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["submitted"] as? Bool,
                    true
                )
                submitted = true
                return try Self.response(for: request, status: 200, json: [:])
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.response(for: request, status: 500, json: [:])
            }
        }

        try await service.submitForReview(
            appID: "app-id",
            versionID: "version-id",
            additionalItems: [
                AppStoreConnectReviewItem(
                    relationship: "subscriptionVersion",
                    resourceType: "subscriptionVersions",
                    id: "subscription-version-id",
                    label: "Premium"
                )
            ],
            intent: .publish
        )

        XCTAssertTrue(resolvedSubscriptionItem)
        XCTAssertTrue(submitted)
    }

    func testNewReviewSubmissionAttachesAndVerifiesEveryDesiredItem() async throws {
        var attachedItems: [[String: Any]] = []
        var submitted = false
        let service = try makeService { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/apps/app-id/reviewSubmissions"):
                return try Self.response(for: request, status: 200, json: ["data": []])
            case ("POST", "/v1/reviewSubmissions"):
                return try Self.response(for: request, status: 201, json: [
                    "data": Self.submission(id: "new-submission", state: "READY_FOR_REVIEW")
                ])
            case ("POST", "/v1/reviewSubmissionItems"):
                let relationships = try Self.relationships(in: request)
                let relationshipName = try XCTUnwrap(
                    ["appStoreVersion", "subscriptionVersion"].first {
                        relationships[$0] != nil
                    }
                )
                let relationship = try XCTUnwrap(relationships[relationshipName] as? [String: Any])
                let related = try XCTUnwrap(relationship["data"] as? [String: Any])
                attachedItems.append(Self.item(
                    id: "item-\(attachedItems.count)",
                    state: "READY_FOR_REVIEW",
                    relationship: relationshipName,
                    type: try XCTUnwrap(related["type"] as? String),
                    relatedID: try XCTUnwrap(related["id"] as? String)
                ))
                return try Self.response(for: request, status: 201, json: [
                    "data": attachedItems.last ?? [:]
                ])
            case ("GET", "/v1/reviewSubmissions/new-submission/items"):
                return try Self.response(for: request, status: 200, json: [
                    "data": attachedItems
                ])
            case ("PATCH", "/v1/reviewSubmissions/new-submission"):
                XCTAssertEqual(
                    try Self.attributes(in: request)["submitted"] as? Bool,
                    true
                )
                submitted = true
                return try Self.response(for: request, status: 200, json: [
                    "data": Self.submission(id: "new-submission", state: "WAITING_FOR_REVIEW")
                ])
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try Self.response(for: request, status: 500, json: [:])
            }
        }

        try await service.submitForReview(
            appID: "app-id",
            versionID: "version-id",
            additionalItems: [
                AppStoreConnectReviewItem(
                    relationship: "subscriptionVersion",
                    resourceType: "subscriptionVersions",
                    id: "subscription-version-id",
                    label: "Premium"
                )
            ],
            intent: .publish
        )

        XCTAssertTrue(submitted)
        XCTAssertEqual(attachedItems.count, 2)
    }

    private func makeService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> AppStoreConnectService {
        ReviewSubmissionURLProtocolStub.configure(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewSubmissionURLProtocolStub.self]
        return try AppStoreConnectService(
            issuerID: "issuer",
            keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: URLSession(configuration: configuration)
        )
    }

    private static func submission(id: String, state: String) -> [String: Any] {
        [
            "type": "reviewSubmissions",
            "id": id,
            "attributes": ["state": state, "platform": "IOS"]
        ]
    }

    private static func item(
        id: String,
        state: String,
        relationship: String,
        type: String,
        relatedID: String
    ) -> [String: Any] {
        [
            "type": "reviewSubmissionItems",
            "id": id,
            "attributes": ["state": state],
            "relationships": [
                relationship: ["data": ["type": type, "id": relatedID]]
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

    private static func attributes(in request: URLRequest) throws -> [String: Any] {
        let data = try requestData(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try XCTUnwrap(root["data"] as? [String: Any])
        return try XCTUnwrap(resource["attributes"] as? [String: Any])
    }

    private static func relationships(in request: URLRequest) throws -> [String: Any] {
        let data = try requestData(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try XCTUnwrap(root["data"] as? [String: Any])
        return try XCTUnwrap(resource["relationships"] as? [String: Any])
    }

    private static func requestData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? AppStoreConnectError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ReviewSubmissionURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func configure(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            self.handler = handler
            recordedRequests = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recordedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let currentHandler = try Self.lock.withLock {
                Self.recordedRequests.append(request)
                return try XCTUnwrap(Self.handler)
            }
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
