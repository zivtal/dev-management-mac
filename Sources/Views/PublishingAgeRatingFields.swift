import SwiftUI

struct PublishingAgeRatingFields: View {
    @Binding var ageRating: [String: AppStoreManifestValue]

    var body: some View {
        ForEach(Self.booleanFields, id: \.key) { field in
            Picker(L10n.text(field.title), selection: booleanBinding(field.key)) {
                Text("Unspecified").tag("")
                Text("No").tag("NO")
                Text("Yes").tag("YES")
            }
        }
        ForEach(Self.frequencyFields, id: \.key) { field in
            Picker(L10n.text(field.title), selection: frequencyBinding(field.key)) {
                Text("Unspecified").tag("")
                Text("None").tag("NONE")
                Text("Infrequent").tag("INFREQUENT")
                Text("Frequent").tag("FREQUENT")
            }
        }
    }

    private func booleanBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                if case .bool(let value) = ageRating[key] { return value ? "YES" : "NO" }
                return ""
            },
            set: { answer in
                switch answer {
                case "YES": ageRating[key] = .bool(true)
                case "NO": ageRating[key] = .bool(false)
                default: ageRating.removeValue(forKey: key)
                }
            }
        )
    }

    private func frequencyBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = ageRating[key] { return value }
                return ""
            },
            set: { answer in
                if answer.isEmpty {
                    ageRating.removeValue(forKey: key)
                } else {
                    ageRating[key] = .string(answer)
                }
            }
        )
    }

    private static let booleanFields = [
        (key: "advertising", title: "Advertising"),
        (key: "gambling", title: "Gambling"),
        (key: "healthOrWellnessTopics", title: "Health or wellness topics"),
        (key: "lootBox", title: "Loot boxes"),
        (key: "messagingAndChat", title: "Messaging and chat"),
        (key: "parentalControls", title: "Parental controls"),
        (key: "ageAssurance", title: "Age assurance"),
        (key: "socialMedia", title: "Social media"),
        (key: "socialMediaAgeRestricted", title: "Age-restricted social media"),
        (key: "unrestrictedWebAccess", title: "Unrestricted web access"),
        (key: "userGeneratedContent", title: "User-generated content")
    ]

    private static let frequencyFields = [
        (key: "alcoholTobaccoOrDrugUseOrReferences", title: "Alcohol, tobacco, or drug references"),
        (key: "contests", title: "Contests"),
        (key: "gamblingSimulated", title: "Simulated gambling"),
        (key: "gunsOrOtherWeapons", title: "Guns or other weapons"),
        (key: "medicalOrTreatmentInformation", title: "Medical or treatment information"),
        (key: "profanityOrCrudeHumor", title: "Profanity or crude humor"),
        (key: "sexualContentGraphicAndNudity", title: "Graphic sexual content or nudity"),
        (key: "sexualContentOrNudity", title: "Sexual content or nudity"),
        (key: "horrorOrFearThemes", title: "Horror or fear themes"),
        (key: "matureOrSuggestiveThemes", title: "Mature or suggestive themes"),
        (key: "violenceCartoonOrFantasy", title: "Cartoon or fantasy violence"),
        (key: "violenceRealisticProlongedGraphicOrSadistic", title: "Prolonged graphic or sadistic violence"),
        (key: "violenceRealistic", title: "Realistic violence")
    ]
}
