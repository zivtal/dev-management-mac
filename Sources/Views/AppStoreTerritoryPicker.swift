import SwiftUI

struct AppStoreTerritoryPicker: View {
    let title: String
    @Binding var selection: String
    let territoryIDs: [String]
    var allowsEmpty = false
    var emptyTitle = "Use default"

    var body: some View {
        Picker(selection: $selection) {
            if allowsEmpty {
                Text(LocalizedStringKey(emptyTitle)).tag("")
            }
            ForEach(options, id: \.self) { territoryID in
                Text(verbatim: Self.displayName(for: territoryID)).tag(territoryID)
            }
        } label: {
            Text(LocalizedStringKey(title))
        }
    }

    private var options: [String] {
        var values = Set(territoryIDs.map { $0.uppercased() })
        if let selected = selection.nilIfEmpty?.uppercased() {
            values.insert(selected)
        }
        if values.isEmpty, !allowsEmpty {
            values.insert("USA")
        }
        return values.sorted {
            Self.displayName(for: $0).localizedCaseInsensitiveCompare(Self.displayName(for: $1))
                == .orderedAscending
        }
    }

    static func displayName(for territoryID: String, locale: Locale = .current) -> String {
        let name = locale.localizedString(forRegionCode: territoryID) ?? territoryID
        return "\(name) (\(territoryID))"
    }
}
