import SwiftUI

struct PublishingPrivacyDraftFields: View {
    @Binding var isSpecified: Bool
    @Binding var collectsData: Bool
    @Binding var dataTypes: [String]
    @Binding var dataUses: [AppStorePrivacyDataUse]
    @Binding var notes: [String]

    var body: some View {
        Picker("The app or its SDKs collect data", selection: collectionAnswer) {
            Text("Unspecified").tag("")
            Text("No").tag("NO")
            Text("Yes").tag("YES")
        }
        DisclosureGroup("Collected data types") {
            Text("Select each data type Apple should list, then its purposes, whether it is linked to the user's identity, and whether it is used for tracking. A type without a purpose keeps publishing manual.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AppStorePrivacyCatalog.groups) { group in
                PublishingPrivacyGroupFields(group: group, dataUses: $dataUses, legacySelected: dataTypes.contains(group.name))
            }
        }
        .disabled(!isSpecified || !collectsData)
        .onChange(of: dataUses) { _, uses in
            // The group checklist mirrors the detailed answers; it never adds to them.
            if !uses.isEmpty || !dataTypes.isEmpty {
                let derived = AppStorePrivacyCatalog.groups(for: uses)
                if derived != dataTypes, !uses.isEmpty { dataTypes = derived }
            }
        }
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
                    dataUses = []
                default:
                    isSpecified = false
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

    static let dataTypeNames = AppStorePrivacyCatalog.groupNames
}

/// One Apple data-type group: a toggle per category, and the purposes, linking,
/// and tracking answers for each selected category.
private struct PublishingPrivacyGroupFields: View {
    let group: AppStorePrivacyCatalog.Group
    @Binding var dataUses: [AppStorePrivacyDataUse]
    /// A legacy draft named the group without categories; keep it visible.
    let legacySelected: Bool

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            ForEach(group.categories) { category in
                Toggle(L10n.text(category.title), isOn: categoryBinding(category.id))
                if let index = dataUses.firstIndex(where: { $0.category == category.id }) {
                    PublishingPrivacyUseFields(use: $dataUses[index])
                        .padding(.leading, 20)
                }
            }
        } label: {
            HStack {
                Text(L10n.text(group.name))
                if legacySelected && selectedCount == 0 {
                    Text("Needs purposes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if selectedCount > 0 {
                    Text(verbatim: "\(selectedCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @State private var isExpanded = false

    private var expansion: Binding<Bool> {
        Binding(
            get: { isExpanded || (legacySelected && selectedCount == 0) },
            set: { isExpanded = $0 }
        )
    }

    private var selectedCount: Int {
        dataUses.filter { use in group.categories.contains { $0.id == use.category } }.count
    }

    private func categoryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { dataUses.contains { $0.category == id } },
            set: { selected in
                if selected, !dataUses.contains(where: { $0.category == id }) {
                    dataUses.append(AppStorePrivacyDataUse(
                        category: id, purposes: [], linkedToUser: false, usedForTracking: false
                    ))
                } else if !selected {
                    dataUses.removeAll { $0.category == id }
                }
            }
        )
    }
}

private struct PublishingPrivacyUseFields: View {
    @Binding var use: AppStorePrivacyDataUse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Purposes")
                .font(.caption)
                .foregroundStyle(use.purposes.isEmpty ? .orange : .secondary)
            ForEach(AppStorePrivacyCatalog.purposes) { purpose in
                Toggle(L10n.text(purpose.title), isOn: purposeBinding(purpose.id))
                    .font(.callout)
            }
            Toggle("Linked to the user's identity", isOn: $use.linkedToUser)
                .font(.callout)
            Toggle("Used for tracking", isOn: $use.usedForTracking)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func purposeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { use.purposes.contains(id) },
            set: { selected in
                if selected, !use.purposes.contains(id) {
                    use.purposes.append(id)
                } else if !selected {
                    use.purposes.removeAll { $0 == id }
                }
            }
        )
    }
}
