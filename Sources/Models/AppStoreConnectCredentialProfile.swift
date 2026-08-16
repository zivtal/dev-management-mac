import Foundation

struct AppStoreConnectCredentialProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var issuerID: String
    var keyID: String

    init(
        id: UUID = UUID(),
        name: String,
        issuerID: String = "",
        keyID: String = ""
    ) {
        self.id = id
        self.name = name
        self.issuerID = issuerID
        self.keyID = keyID
    }
}

struct AppStoreConnectResolvedCredential: Equatable, Sendable {
    let profileID: UUID?
    let name: String
    let issuerID: String
    let keyID: String
}
