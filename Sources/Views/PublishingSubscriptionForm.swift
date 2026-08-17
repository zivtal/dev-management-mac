import SwiftUI

struct PublishingSubscriptionLocalizationForm: Identifiable {
    let id: UUID
    var locale: String
    var name: String
    var description: String

    init(
        id: UUID = UUID(),
        locale: String = "en-US",
        name: String = "",
        description: String = ""
    ) {
        self.id = id
        self.locale = locale
        self.name = name
        self.description = description
    }

    init(_ localization: AppStoreSubscriptionLocalization) {
        self.init(
            locale: localization.locale,
            name: localization.name,
            description: localization.description ?? ""
        )
    }

    var definition: AppStoreSubscriptionLocalization {
        AppStoreSubscriptionLocalization(
            locale: locale,
            name: name,
            description: description.nilIfEmpty
        ).normalizingLocale()
    }
}

struct PublishingTerritoryPriceForm: Identifiable {
    let id: UUID
    var territory: String
    var price: String

    init(id: UUID = UUID(), territory: String = "", price: String = "") {
        self.id = id
        self.territory = territory
        self.price = price
    }
}

struct PublishingSubscriptionProductForm: Identifiable {
    let id: UUID
    var referenceName: String
    var productID: String
    var period: String
    var basePrice: String
    var baseTerritory: String
    var territoryPrices: [PublishingTerritoryPriceForm]
    var availableInAllTerritories: Bool
    var familySharable: Bool
    var groupLevel: String
    var reviewNote: String
    var reviewScreenshot: String
    var localizations: [PublishingSubscriptionLocalizationForm]

    init(
        id: UUID = UUID(),
        referenceName: String = "",
        productID: String = "",
        period: String = "ONE_MONTH",
        basePrice: String = "",
        baseTerritory: String = "",
        territoryPrices: [PublishingTerritoryPriceForm] = [],
        availableInAllTerritories: Bool = true,
        familySharable: Bool = true,
        groupLevel: String = "1",
        reviewNote: String = "",
        reviewScreenshot: String = "",
        localizations: [PublishingSubscriptionLocalizationForm] = []
    ) {
        self.id = id
        self.referenceName = referenceName
        self.productID = productID
        self.period = period
        self.basePrice = basePrice
        self.baseTerritory = baseTerritory
        self.territoryPrices = territoryPrices
        self.availableInAllTerritories = availableInAllTerritories
        self.familySharable = familySharable
        self.groupLevel = groupLevel
        self.reviewNote = reviewNote
        self.reviewScreenshot = reviewScreenshot
        self.localizations = localizations
    }

    init(_ definition: AppStoreSubscriptionDefinition) {
        self.init(
            referenceName: definition.referenceName,
            productID: definition.productID,
            period: definition.period,
            basePrice: definition.basePrice ?? "",
            baseTerritory: definition.baseTerritory ?? "",
            territoryPrices: (definition.territoryPrices ?? [:])
                .sorted(by: { $0.key < $1.key })
                .map { PublishingTerritoryPriceForm(territory: $0.key, price: $0.value) },
            availableInAllTerritories: definition.availableInAllTerritories ?? true,
            familySharable: definition.familySharable ?? true,
            groupLevel: definition.groupLevel.map(String.init) ?? "1",
            reviewNote: definition.reviewNote ?? "",
            reviewScreenshot: definition.reviewScreenshot ?? "",
            localizations: (definition.localizations ?? []).map(PublishingSubscriptionLocalizationForm.init)
        )
    }

    var definition: AppStoreSubscriptionDefinition {
        let prices = territoryPrices.reduce(into: [String: String]()) { result, entry in
                guard let territory = entry.territory.nilIfEmpty,
                      let price = entry.price.nilIfEmpty else { return }
                result[territory.uppercased()] = price
            }
        return AppStoreSubscriptionDefinition(
            referenceName: referenceName,
            productID: productID,
            period: period,
            basePrice: basePrice.nilIfEmpty,
            baseTerritory: baseTerritory.nilIfEmpty?.uppercased(),
            territoryPrices: prices.isEmpty ? nil : prices,
            availableInAllTerritories: availableInAllTerritories,
            familySharable: familySharable,
            groupLevel: Int(groupLevel),
            reviewNote: reviewNote.nilIfEmpty,
            reviewScreenshot: reviewScreenshot.nilIfEmpty,
            localizations: localizations.isEmpty ? nil : localizations.map(\.definition)
        )
    }
}

struct PublishingSubscriptionGroupForm: Identifiable {
    let id: UUID
    var referenceName: String
    var localizations: [PublishingSubscriptionLocalizationForm]
    var subscriptions: [PublishingSubscriptionProductForm]

    init(
        id: UUID = UUID(),
        referenceName: String = "",
        localizations: [PublishingSubscriptionLocalizationForm] = [],
        subscriptions: [PublishingSubscriptionProductForm] = []
    ) {
        self.id = id
        self.referenceName = referenceName
        self.localizations = localizations
        self.subscriptions = subscriptions
    }

    init(_ definition: AppStoreSubscriptionGroupDefinition) {
        self.init(
            referenceName: definition.referenceName,
            localizations: (definition.localizations ?? []).map(PublishingSubscriptionLocalizationForm.init),
            subscriptions: definition.subscriptions.map(PublishingSubscriptionProductForm.init)
        )
    }

    var definition: AppStoreSubscriptionGroupDefinition {
        AppStoreSubscriptionGroupDefinition(
            referenceName: referenceName,
            localizations: localizations.isEmpty ? nil : localizations.map(\.definition),
            subscriptions: subscriptions.map(\.definition)
        )
    }
}

struct PublishingSubscriptionForm: View {
    @Binding var baseTerritory: String
    @Binding var availableInAllTerritories: Bool
    @Binding var familySharable: Bool
    @Binding var reviewScreenshot: String
    @Binding var groups: [PublishingSubscriptionGroupForm]
    let territoryIDs: [String]

    var body: some View {
        GeometryReader { geometry in
            switch PublishingWindowLayout(width: geometry.size.width) {
            case .threeColumns:
                HStack(alignment: .top, spacing: 16) {
                    subscriptionForm {
                        subscriptionDefaultsSection
                    }
                    .frame(width: max(360, (geometry.size.width - 32) / 3))
                    subscriptionForm {
                        groupsAndProductsSection
                    }
                }
            case .twoColumns:
                HStack(alignment: .top, spacing: 16) {
                    subscriptionForm {
                        subscriptionDefaultsSection
                    }
                    subscriptionForm {
                        groupsAndProductsSection
                    }
                }
            case .singleColumn:
                subscriptionForm {
                    subscriptionDefaultsSection
                    groupsAndProductsSection
                }
            }
        }
    }

    private func subscriptionForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subscriptionDefaultsSection: some View {
        Section("Subscription Defaults") {
            AppStoreTerritoryPicker(
                title: "Base territory",
                selection: $baseTerritory,
                territoryIDs: territoryIDs,
                allowsEmpty: true,
                emptyTitle: "Use USA default"
            )
            Toggle("Available in all territories", isOn: $availableInAllTerritories)
            Toggle("Enable Family Sharing for all subscriptions", isOn: $familySharable)
                .onChange(of: familySharable) { _, enabled in
                    for groupIndex in groups.indices {
                        for productIndex in groups[groupIndex].subscriptions.indices {
                            groups[groupIndex].subscriptions[productIndex].familySharable = enabled
                        }
                    }
                }
            Text("Apple applies Family Sharing per subscription. This default updates every product below; each product can still be adjusted individually. Enabling it may be effectively one-way after subscribers exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Default review screenshot", text: $reviewScreenshot)
        }
    }

    private var groupsAndProductsSection: some View {
        Section("Groups and Products") {
            if groups.isEmpty {
                Text("No subscription groups are configured.")
                    .foregroundStyle(.secondary)
            }
            ForEach($groups) { $group in
                DisclosureGroup(group.referenceName.nilIfEmpty ?? L10n.text("New subscription group")) {
                    TextField("Group reference name", text: $group.referenceName)
                    localizationEditor(localizations: $group.localizations)

                    ForEach($group.subscriptions) { $product in
                        productEditor(product: $product)
                    }
                    Button {
                        group.subscriptions.append(PublishingSubscriptionProductForm())
                    } label: {
                        Label("Add subscription product", systemImage: "plus")
                    }
                }
                Button(role: .destructive) {
                    groups.removeAll { $0.id == group.id }
                } label: {
                    Label("Remove subscription group", systemImage: "trash")
                }
            }
            Button {
                groups.append(PublishingSubscriptionGroupForm())
            } label: {
                Label("Add subscription group", systemImage: "plus")
            }
            Text("Every subscription value is editable here. Advanced JSON is optional and exposes the same saved configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func productEditor(product: Binding<PublishingSubscriptionProductForm>) -> some View {
        DisclosureGroup(product.wrappedValue.referenceName.nilIfEmpty ?? L10n.text("New subscription product")) {
            TextField("Product reference name", text: product.referenceName)
            TextField("Product ID", text: product.productID)
            Picker("Duration", selection: product.period) {
                ForEach(Self.periods, id: \.self) { period in
                    Text(period.replacingOccurrences(of: "_", with: " ").capitalized).tag(period)
                }
            }
            TextField("Base price", text: product.basePrice)
            AppStoreTerritoryPicker(
                title: "Base territory override",
                selection: product.baseTerritory,
                territoryIDs: territoryIDs,
                allowsEmpty: true,
                emptyTitle: "Use subscription default"
            )
            Toggle("Available in all territories", isOn: product.availableInAllTerritories)
            Toggle("Family Sharing", isOn: product.familySharable)
            TextField("Subscription group level", text: product.groupLevel)
            TextField("Review note", text: product.reviewNote)
            TextField("Review screenshot", text: product.reviewScreenshot)

            DisclosureGroup("Territory price overrides") {
                if product.wrappedValue.territoryPrices.isEmpty {
                    Text("No territory price overrides.")
                        .foregroundStyle(.secondary)
                }
                ForEach(product.territoryPrices) { $entry in
                    HStack {
                        TextField("Territory", text: $entry.territory)
                        TextField("Price", text: $entry.price)
                        Button(role: .destructive) {
                            product.wrappedValue.territoryPrices.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    product.wrappedValue.territoryPrices.append(PublishingTerritoryPriceForm())
                } label: {
                    Label("Add territory price", systemImage: "plus")
                }
            }

            localizationEditor(localizations: product.localizations)
            Button(role: .destructive) {
                for groupIndex in groups.indices {
                    groups[groupIndex].subscriptions.removeAll { $0.id == product.wrappedValue.id }
                }
            } label: {
                Label("Remove subscription product", systemImage: "trash")
            }
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private func localizationEditor(
        localizations: Binding<[PublishingSubscriptionLocalizationForm]>
    ) -> some View {
        DisclosureGroup("Localizations") {
            if localizations.wrappedValue.isEmpty {
                Text("No subscription localizations are configured.")
                    .foregroundStyle(.secondary)
            }
            ForEach(localizations) { $localization in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Locale", text: $localization.locale)
                        TextField("Display name", text: $localization.name)
                        Button(role: .destructive) {
                            localizations.wrappedValue.removeAll { $0.id == localization.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    TextField("Description", text: $localization.description)
                }
            }
            Button {
                localizations.wrappedValue.append(PublishingSubscriptionLocalizationForm())
            } label: {
                Label("Add localization", systemImage: "plus")
            }
        }
    }

    private static let periods = [
        "ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS",
        "SIX_MONTHS", "ONE_YEAR"
    ]
}
