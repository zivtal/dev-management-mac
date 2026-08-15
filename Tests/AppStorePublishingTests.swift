import CryptoKit
import XCTest
@testable import DevManagement

final class AppStorePublishingTests: XCTestCase {
    func testOpenAIRequestUsesStrictStructuredOutputAndDisablesStorage() throws {
        let body = OpenAIStoreMetadataService.requestBody(
            model: "gpt-5.6-luna",
            prompt: "Project information"
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testOpenAIResponseDecodesStructuredMetadata() throws {
        let generated = AppStoreMetadata(
            description: "A useful application.",
            keywords: "useful,application",
            promotionalText: "Try it today.",
            whatsNew: "Performance improvements."
        )
        let generatedData = try JSONEncoder().encode(generated)
        let generatedJSON = try XCTUnwrap(String(data: generatedData, encoding: .utf8))
        let response: [String: Any] = [
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": generatedJSON]]
            ]]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response)

        XCTAssertEqual(try OpenAIStoreMetadataService.decodeMetadata(from: responseData), generated)
    }

    func testGeneratedMetadataIsLimitedToAppStoreLengths() {
        let metadata = AppStoreMetadata(
            description: String(repeating: "d", count: 4_100),
            keywords: String(repeating: "é", count: 60),
            promotionalText: String(repeating: "p", count: 200),
            whatsNew: String(repeating: "n", count: 4_100)
        ).normalized()

        XCTAssertEqual(metadata.description.count, 4_000)
        XCTAssertLessThanOrEqual(metadata.keywords.lengthOfBytes(using: .utf8), 100)
        XCTAssertEqual(metadata.promotionalText.count, 170)
        XCTAssertEqual(metadata.whatsNew.count, 4_000)
    }

    func testScreenshotDimensionsMapToAppStoreDisplayTypes() {
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(width: 1_320, height: 2_868),
            "APP_IPHONE_67"
        )
        XCTAssertEqual(
            AppStorePublishingService.screenshotDisplayType(width: 2_752, height: 2_064),
            "APP_IPAD_PRO_3GEN_129"
        )
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 800, height: 600))
    }

    func testAppStoreConnectJWTContainsExpectedClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try AppStoreConnectService.jwt(
            issuerID: "issuer-id",
            keyID: "KEY123",
            privateKey: privateKey,
            now: now
        )
        let components = token.split(separator: ".")
        XCTAssertEqual(components.count, 3)

        let header = try decodedJWTComponent(String(components[0]))
        let payload = try decodedJWTComponent(String(components[1]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY123")
        XCTAssertEqual(payload["iss"] as? String, "issuer-id")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(payload["exp"] as? Int, 1_800_001_100)
    }

    func testLegacyPreferencesDecodeWithoutPublishingFields() throws {
        let data = Data(#"{"automationEnabled":true,"reinstallAfterDays":3,"launchAtLogin":true,"pollIntervalSeconds":300}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertNil(preferences.openAIModel)
        XCTAssertNil(preferences.appStoreConnectIssuerID)
        XCTAssertNil(preferences.appStoreSubmitForReview)
    }

    private func decodedJWTComponent(_ component: String) throws -> [String: Any] {
        var base64 = component.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
