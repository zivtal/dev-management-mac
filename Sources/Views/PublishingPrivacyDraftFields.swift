import SwiftUI

struct PublishingPrivacyDraftFields: View {
    @Binding var isSpecified: Bool
    @Binding var collectsData: Bool
    @Binding var dataTypes: [String]
    @Binding var notes: [String]

    var body: some View {
        Picker("The app or its SDKs collect data", selection: collectionAnswer) {
            Text("Unspecified").tag("")
            Text("No").tag("NO")
            Text("Yes").tag("YES")
        }
        DisclosureGroup("Potential data types") {
            ForEach(Self.dataTypeNames, id: \.self) { dataType in
                Toggle(L10n.text(dataType), isOn: dataTypeBinding(dataType))
            }
        }
        .disabled(!isSpecified || !collectsData)
        VStack(alignment: .leading, spacing: 5) {
            Text("Privacy review notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: notesBinding)
                .frame(height: 150)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!isSpecified)
    }

    private var collectionAnswer: Binding<String> {
        Binding(
            get: {
                guard isSpecified else { return "" }
                return collectsData ? "YES" : "NO"
            },
            set: { answer in
                switch answer {
                case "YES":
                    isSpecified = true
                    collectsData = true
                case "NO":
                    isSpecified = true
                    collectsData = false
                    dataTypes = []
                default:
                    isSpecified = false
                }
            }
        )
    }

    private func dataTypeBinding(_ dataType: String) -> Binding<Bool> {
        Binding(
            get: { dataTypes.contains(dataType) },
            set: { selected in
                if selected, !dataTypes.contains(dataType) {
                    dataTypes.append(dataType)
                } else if !selected {
                    dataTypes.removeAll { $0 == dataType }
                }
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { notes.joined(separator: "\n") },
            set: {
                notes = $0.split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .compactMap(\.nilIfEmpty)
            }
        )
    }

    private static let dataTypeNames = [
        "Contact Info", "Health & Fitness", "Financial Info", "Location",
        "Sensitive Info", "Contacts", "User Content", "Browsing History",
        "Search History", "Identifiers", "Purchases", "Usage Data",
        "Diagnostics", "Other Data"
    ]
}
