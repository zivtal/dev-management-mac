import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PublishingWindowPresenter {
    static let shared = PublishingWindowPresenter()

    private var windowController: NSWindowController?

    private init() {}

    func show(model: AppModel, projectID: UUID? = nil) {
        windowController?.close()
        let rootView = PublishingWindowView(initialProjectID: projectID)
            .environmentObject(model)
        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("Publish to the App Store")
        panel.contentViewController = hostingController
        panel.isFloatingPanel = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 580)
        panel.center()
        windowController = NSWindowController(window: panel)

        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        windowController?.close()
    }
}

private struct PublishingWindowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var selectedProjectID: UUID?
    @State private var subscriptionSummary: SubscriptionSummary = .loading
    @State private var selectedAction = PublishingAction.release
    @State private var configurationRevision = 0
    @State private var showsPerAppConfiguration = false
    @State private var showsConfirmation = false
    @State private var showsCodeConfirmation = false
    @State private var selectedProductID = ""
    @State private var offerReferenceName = "Friends and Press"
    @State private var offerDuration = SubscriptionOfferDuration.oneMonth
    @State private var offerEligibilities = Set(SubscriptionOfferCustomerEligibility.allCases)
    @State private var stackWithIntroductoryOffer = false
    @State private var autoRenewEnabled = true
    @State private var codeKind = SubscriptionOfferCodeKind.oneTime
    @State private var numberOfCodes = 500
    @State private var customCode = ""
    @State private var customHasExpiration = false
    @State private var expirationDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var codeStatus: CodeStatus?
    @State private var submitForReviewSelection = true
    @State private var releaseAutomaticallySelection = true

    init(initialProjectID: UUID?) {
        _selectedProjectID = State(initialValue: initialProjectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if eligibleProjects.isEmpty {
                ContentUnavailableView(
                    "No publishable application",
                    systemImage: "shippingbox",
                    description: Text("Add an iOS application that uses Direct Xcode build.")
                )
            } else if let project = selectedProject {
                projectOptions(project)
                Spacer(minLength: 0)
                footer(project)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .onAppear {
            if selectedProject == nil {
                selectedProjectID = eligibleProjects.first?.id
            }
        }
        .task(id: configurationTaskID) {
            await refreshSubscriptionSummary()
        }
        .sheet(isPresented: $showsPerAppConfiguration) {
            if let project = selectedProject {
                PerAppPublishingConfigurationEditor(
                    project: project,
                    defaults: model.preferences,
                    onSave: {
                        configurationRevision += 1
                        showsPerAppConfiguration = false
                    }
                )
            }
        }
        .onChange(of: codeKind) { _, kind in
            if kind == .oneTime, numberOfCodes < 500 {
                numberOfCodes = 500
            } else if kind == .custom, numberOfCodes == 500 {
                numberOfCodes = 100
            }
        }
        .confirmationDialog(
            Text("Publish to the App Store?"),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(submitForReview ? "Build, upload, and submit" : "Build and upload") {
                guard let projectID = selectedProjectID else { return }
                model.publish(
                    projectID: projectID,
                    submitForReview: submitForReview,
                    releaseAutomatically: releaseAutomatically
                )
                if model.publishingProgress != nil {
                    PublishingWindowPresenter.shared.close()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This production action archives and uploads the selected build. First publications also reconcile app setup and subscriptions discovered in the project; later versions reuse the approved setup.")
        }
        .confirmationDialog(
            Text("Generate production offer codes?"),
            isPresented: $showsCodeConfirmation,
            titleVisibility: .visible
        ) {
            Button(codeKind == .oneTime ? "Generate one-time codes" : "Create custom code") {
                Task { await generateOfferCodes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates an immutable free subscription offer and a production code batch in App Store Connect. The app and subscription must already be approved for production codes.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Publish to the App Store")
                    .font(.title2.bold())
                Text("Review the target and options before the production upload.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func projectOptions(_ project: ManagedProject) -> some View {
        Form {
            Section("Application") {
                Picker("Application", selection: $selectedProjectID) {
                    ForEach(eligibleProjects) { candidate in
                        Text(candidate.displayName).tag(Optional(candidate.id))
                    }
                }
                LabeledContent("Bundle identifier", value: project.bundleIdentifier ?? L10n.text("Unknown"))
                LabeledContent("Version", value: project.marketingVersion ?? L10n.text("Unknown"))
                LabeledContent("Build", value: project.buildNumber ?? L10n.text("Unknown"))
                Button {
                    showsPerAppConfiguration = true
                } label: {
                    Label("Per-App Configuration…", systemImage: "doc.badge.gearshape")
                }
            }

            Picker("Action", selection: $selectedAction) {
                Text("App Release").tag(PublishingAction.release)
                Text("Offer Codes").tag(PublishingAction.offerCodes)
            }
            .pickerStyle(.segmented)

            if selectedAction == .release {
                releaseOptions
            } else {
                offerCodeOptions
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var releaseOptions: some View {
        Section("Subscriptions") {
            subscriptionDiscoveryStatus
            Text("For a first publication, local .storekit files and app-store-publishing.json are reconciled with App Store Connect. If an older version is already published, these resources are preserved and only the new version is uploaded and submitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Submission") {
            Toggle("Submit the uploaded version for App Review", isOn: $submitForReviewSelection)
            Toggle("Release automatically after Apple approves it", isOn: $releaseAutomaticallySelection)
                .disabled(!submitForReview)
        }
    }

    @ViewBuilder
    private var offerCodeOptions: some View {
        Section("Subscription") {
            subscriptionDiscoveryStatus
            if !detectedProductIDs.isEmpty {
                Picker("Product", selection: $selectedProductID) {
                    ForEach(detectedProductIDs, id: \.self) { productID in
                        Text(productID).tag(productID)
                    }
                }
            }
            Text("Production codes require an app that is ready for distribution and an approved subscription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Free Offer") {
            TextField("Reference name", text: $offerReferenceName)
            Picker("Free access duration", selection: $offerDuration) {
                ForEach(SubscriptionOfferDuration.allCases, id: \.self) { duration in
                    Text(duration.title).tag(duration)
                }
            }
            LabeledContent("Eligible subscribers") {
                HStack(spacing: 14) {
                    ForEach(SubscriptionOfferCustomerEligibility.allCases, id: \.self) { eligibility in
                        Toggle(eligibility.title, isOn: eligibilityBinding(eligibility))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            Toggle("Allow the introductory offer before this offer", isOn: $stackWithIntroductoryOffer)
            Toggle("Automatically renew at the standard price", isOn: $autoRenewEnabled)
            Text("Apple does not allow an offer's terms to be edited after creation. Reusing the same reference name reuses only an exact match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Codes") {
            Picker("Code type", selection: $codeKind) {
                ForEach(SubscriptionOfferCodeKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            LabeledContent(codeKind == .oneTime ? "Number of unique codes" : "Redemption cap") {
                TextField("Quantity", value: $numberOfCodes, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            if codeKind == .custom {
                TextField("Custom code", text: $customCode)
                    .onChange(of: customCode) { _, value in
                        let uppercased = value.uppercased()
                        if uppercased != value { customCode = uppercased }
                    }
                Toggle("Set an expiration date", isOn: $customHasExpiration)
            }
            if codeKind == .oneTime || customHasExpiration {
                DatePicker(
                    "Expiration date",
                    selection: $expirationDate,
                    in: earliestExpirationDate...latestExpirationDate,
                    displayedComponents: .date
                )
            }
            Text(codeKind == .oneTime
                ? "Apple permits 500–25,000 unique production codes per batch. The downloaded CSV includes the redeemable values."
                : "Custom codes use letters and numbers only, up to 64 characters, with 1–25,000 redemptions per batch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let codeStatus {
                codeStatusView(codeStatus)
            }
        }
    }

    @ViewBuilder
    private var subscriptionDiscoveryStatus: some View {
        switch subscriptionSummary {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Inspecting the app project…")
                    .foregroundStyle(.secondary)
            }
        case .none:
            Label("No subscription products detected", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .found(let productIDs, let sources):
            Label(
                L10n.format("%d subscription product(s) detected", productIDs.count),
                systemImage: "creditcard.fill"
            )
            if !sources.isEmpty {
                Text(sources.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func footer(_ project: ManagedProject) -> some View {
        HStack {
            Button("Publishing Settings…") {
                openSettings()
            }
            Spacer()
            Button("Cancel") {
                PublishingWindowPresenter.shared.close()
            }
            Button {
                if selectedAction == .release {
                    showsConfirmation = true
                } else {
                    showsCodeConfirmation = true
                }
            } label: {
                if model.isGeneratingOfferCodes {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        selectedAction == .release ? "Publish" : "Generate Codes",
                        systemImage: selectedAction == .release ? "paperplane.fill" : "ticket.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.hasActiveWork || !actionIsValid(project))
        }
    }

    private var eligibleProjects: [ManagedProject] {
        model.projects.filter { !$0.isMacOSApplication && $0.installMethod == .xcodebuild }
    }

    private var selectedProject: ManagedProject? {
        guard let selectedProjectID else { return nil }
        return eligibleProjects.first(where: { $0.id == selectedProjectID })
    }

    private var submitForReview: Bool {
        submitForReviewSelection
    }

    private var releaseAutomatically: Bool {
        releaseAutomaticallySelection
    }

    private func refreshSubscriptionSummary() async {
        guard let project = selectedProject else {
            subscriptionSummary = .none
            return
        }
        subscriptionSummary = .loading
        do {
            let catalog = try StoreKitSubscriptionDiscoveryService().discover(
                project: project,
                defaultLocale: model.preferences.appStoreLocale?.nilIfEmpty ?? "en-US"
            )
            submitForReviewSelection = catalog.publication?.submitForReview
                ?? model.preferences.appStoreSubmitForReview
                ?? true
            releaseAutomaticallySelection = catalog.publication?.releaseAutomatically
                ?? model.preferences.appStoreReleaseAutomatically
                ?? true
            if catalog.detectedProductIDs.isEmpty {
                subscriptionSummary = .none
                selectedProductID = ""
            } else {
                let productIDs = catalog.detectedProductIDs.sorted()
                subscriptionSummary = .found(
                    productIDs: productIDs,
                    sources: catalog.sourceFiles
                )
                if !productIDs.contains(selectedProductID) {
                    selectedProductID = productIDs.first ?? ""
                }
            }
        } catch {
            subscriptionSummary = .error(error.localizedDescription)
        }
    }

    private enum SubscriptionSummary: Equatable {
        case loading
        case none
        case found(productIDs: [String], sources: [String])
        case error(String)

        var hasError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    private enum PublishingAction: Hashable {
        case release
        case offerCodes
    }

    private enum CodeStatus: Equatable {
        case success(String)
        case warning(String)
        case failure(String)
    }

    private var detectedProductIDs: [String] {
        guard case .found(let productIDs, _) = subscriptionSummary else { return [] }
        return productIDs
    }

    private var configurationTaskID: String {
        "\(selectedProjectID?.uuidString ?? "none")-\(configurationRevision)"
    }

    private var earliestExpirationDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var latestExpirationDate: Date {
        Calendar.current.date(byAdding: .month, value: 6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private func eligibilityBinding(
        _ eligibility: SubscriptionOfferCustomerEligibility
    ) -> Binding<Bool> {
        Binding(
            get: { offerEligibilities.contains(eligibility) },
            set: { enabled in
                if enabled {
                    offerEligibilities.insert(eligibility)
                } else {
                    offerEligibilities.remove(eligibility)
                }
            }
        )
    }

    private func actionIsValid(_ project: ManagedProject) -> Bool {
        guard project.bundleIdentifier?.isEmpty == false, !subscriptionSummary.hasError else {
            return false
        }
        if selectedAction == .release {
            return project.marketingVersion?.isEmpty == false && project.buildNumber?.isEmpty == false
        }
        guard !selectedProductID.isEmpty,
              offerReferenceName.nilIfEmpty != nil,
              !offerEligibilities.isEmpty else { return false }
        if codeKind == .oneTime {
            return (500...25_000).contains(numberOfCodes)
        }
        return (1...25_000).contains(numberOfCodes)
            && (1...64).contains(customCode.count)
            && customCode.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private func generateOfferCodes() async {
        guard let projectID = selectedProjectID else { return }
        let saveURL: URL?
        if codeKind == .oneTime {
            let panel = NSSavePanel()
            panel.title = L10n.text("Save One-Time Offer Codes")
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(selectedProductID.replacingOccurrences(of: ".", with: "-"))-offer-codes.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            saveURL = url
        } else {
            saveURL = nil
        }

        codeStatus = nil
        let request = SubscriptionOfferCodeGenerationRequest(
            productID: selectedProductID,
            offer: SubscriptionOfferConfiguration(
                referenceName: offerReferenceName.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: offerDuration,
                customerEligibilities: offerEligibilities,
                stackWithIntroductoryOffer: stackWithIntroductoryOffer,
                autoRenewEnabled: autoRenewEnabled
            ),
            kind: codeKind,
            numberOfCodes: numberOfCodes,
            expirationDate: codeKind == .oneTime || customHasExpiration ? expirationDate : nil,
            customCode: codeKind == .custom ? customCode : nil
        )
        do {
            let result = try await model.generateSubscriptionOfferCodes(
                projectID: projectID,
                request: request
            )
            if let csv = result.oneTimeCodeCSV, let saveURL {
                try csv.write(to: saveURL, options: .atomic)
                codeStatus = .success(L10n.format("Generated %d codes and saved %@.", numberOfCodes, saveURL.lastPathComponent))
            } else if codeKind == .oneTime {
                codeStatus = .warning(L10n.format("The batch was created, but Apple is still preparing its CSV. Batch ID: %@", result.batchID))
            } else {
                codeStatus = .success(L10n.format("Custom code %@ was created with %d redemptions.", result.customCode ?? customCode, numberOfCodes))
            }
        } catch {
            codeStatus = .failure(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func codeStatusView(_ status: CodeStatus) -> some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning(let message):
            Label(message, systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct PerAppPublishingConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss

    let project: ManagedProject
    let defaults: AppPreferences
    let onSave: () -> Void

    @State private var json = ""
    @State private var validationMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per-App Publishing Configuration")
                        .font(.title2.bold())
                    Text(project.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Insert Manual Metadata Fields") {
                    insertManualMetadataFields()
                }
                .disabled(isLoading)
            }

            Text("This JSON belongs to the selected app. Omit metadata to generate it with OpenAI, or fill all metadata fields to use your text. Relative screenshot and subscription review-screenshot paths are resolved from the project folder. API credentials and demo passwords remain in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLoading {
                Spacer()
                ProgressView("Loading configuration…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                TextEditor(text: $json)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    }
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Saved as app-store-publishing.json in the app project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Validate and Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 640)
        .task { load() }
    }

    private var configurationURL: URL {
        project.folderURL.appendingPathComponent("app-store-publishing.json")
    }

    private func load() {
        defer { isLoading = false }
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                json = try String(contentsOf: configurationURL, encoding: .utf8)
                return
            }
            let catalog = try StoreKitSubscriptionDiscoveryService().discover(
                project: project,
                defaultLocale: defaults.appStoreLocale?.nilIfEmpty ?? "en-US"
            )
            let firstSubscription = catalog.groups.first?.subscriptions.first
            let manifest = AppStorePublishingManifest(
                schemaVersion: 1,
                publication: defaultPublicationConfiguration(),
                application: catalog.application,
                subscriptions: AppStoreSubscriptionsConfiguration(
                    baseTerritory: firstSubscription?.baseTerritory,
                    availableInAllTerritories: firstSubscription?.availableInAllTerritories,
                    reviewScreenshot: firstSubscription?.reviewScreenshot,
                    groups: catalog.groups.isEmpty ? nil : catalog.groups
                )
            )
            json = try Self.encoded(manifest)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func insertManualMetadataFields() {
        do {
            var manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: Data(json.utf8))
            var publication = manifest.publication ?? defaultPublicationConfiguration()
            publication.metadata = publication.metadata ?? AppStoreMetadata(
                description: "",
                keywords: "",
                promotionalText: "",
                whatsNew: ""
            )
            manifest.publication = publication
            json = try Self.encoded(manifest)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let data = Data(json.utf8)
            let manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: data)
            try validate(manifest)
            let formatted = try Self.encoded(manifest)
            try Data(formatted.utf8).write(to: configurationURL, options: .atomic)
            json = formatted
            validationMessage = nil
            onSave()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func validate(_ manifest: AppStorePublishingManifest) throws {
        guard manifest.schemaVersion == nil || manifest.schemaVersion == 1 else {
            throw ConfigurationEditorError.invalid(L10n.text("schemaVersion must be 1."))
        }
        if let supportURL = manifest.publication?.supportURL?.nilIfEmpty {
            guard let url = URL(string: supportURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                throw ConfigurationEditorError.invalid(L10n.text("publication.supportURL must be a valid HTTP or HTTPS URL."))
            }
        }
        if let metadata = manifest.publication?.metadata,
           metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigurationEditorError.invalid(L10n.text("Manual metadata requires a non-empty description."))
        }
        var productIDs: Set<String> = []
        for group in manifest.subscriptions?.groups ?? [] {
            guard group.referenceName.nilIfEmpty != nil else {
                throw ConfigurationEditorError.invalid(L10n.text("Every subscription group requires a referenceName."))
            }
            for subscription in group.subscriptions {
                guard subscription.productID.nilIfEmpty != nil,
                      productIDs.insert(subscription.productID).inserted else {
                    throw ConfigurationEditorError.invalid(L10n.text("Subscription product IDs must be non-empty and unique."))
                }
                _ = try StoreKitSubscriptionDiscoveryService.applePeriod(
                    subscription.period,
                    productID: subscription.productID
                )
            }
        }
    }

    private func defaultPublicationConfiguration() -> AppStorePublicationConfiguration {
        AppStorePublicationConfiguration(
            locale: defaults.appStoreLocale?.nilIfEmpty ?? "en-US",
            copyright: defaults.appStoreCopyright,
            supportURL: defaults.appStoreSupportURL,
            submitForReview: defaults.appStoreSubmitForReview ?? true,
            releaseAutomatically: defaults.appStoreReleaseAutomatically ?? true,
            metadata: nil,
            screenshotPaths: ["Screenshots"],
            review: AppStoreReviewManifestConfiguration(
                contactFirstName: defaults.appStoreReviewFirstName,
                contactLastName: defaults.appStoreReviewLastName,
                contactPhone: defaults.appStoreReviewPhone,
                contactEmail: defaults.appStoreReviewEmail,
                notes: defaults.appStoreReviewNotes,
                demoAccountRequired: defaults.appStoreReviewDemoAccountRequired ?? false
            )
        )
    }

    private static func encoded(_ manifest: AppStorePublishingManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard let result = String(data: data, encoding: .utf8) else {
            throw ConfigurationEditorError.invalid(L10n.text("Could not encode the configuration as UTF-8."))
        }
        return result + "\n"
    }

    private enum ConfigurationEditorError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            }
        }
    }
}
