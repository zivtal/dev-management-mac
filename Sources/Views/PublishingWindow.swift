import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PublishingWindowLayout: Equatable {
    case singleColumn
    case twoColumns
    case threeColumns

    init(width: CGFloat) {
        if width >= 1_500 {
            self = .threeColumns
        } else if width >= 900 {
            self = .twoColumns
        } else {
            self = .singleColumn
        }
    }
}

private enum PublishingWorkspace: String, CaseIterable {
    case overview
    case configuration

    var title: String {
        switch self {
        case .overview: L10n.text("Publish Overview")
        case .configuration: L10n.text("Publishing Configuration")
        }
    }
}

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
        if let screen = NSApplication.shared.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(screen.visibleFrame, display: false)
        } else {
            panel.center()
        }
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
    @State private var localPublishingPreview: LocalPublishingPreview?
    @State private var appStoreConfiguration: AppStoreConfigurationState = .loading
    @State private var selectedAction = PublishingAction.release
    @State private var configurationRevision = 0
    @State private var selectedWorkspace = PublishingWorkspace.overview
    @State private var configurationEditorStartsWithAI = false
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
                Picker("Workspace", selection: $selectedWorkspace) {
                    ForEach(PublishingWorkspace.allCases, id: \.self) { workspace in
                        Text(workspace.title).tag(workspace)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if selectedWorkspace == .overview {
                    projectOptions(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer(project)
                } else {
                    PerAppPublishingConfigurationEditor(
                        project: project,
                        defaults: model.preferences,
                        currentConfiguration: currentAppStoreSnapshot,
                        generateAIDraftOnOpen: configurationEditorStartsWithAI,
                        onCancel: {
                            configurationEditorStartsWithAI = false
                            selectedWorkspace = .overview
                        },
                        onSave: {
                            configurationRevision += 1
                            configurationEditorStartsWithAI = false
                            selectedWorkspace = .overview
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedProject == nil {
                selectedProjectID = eligibleProjects.first?.id
            }
        }
        .task(id: configurationTaskID) {
            await refreshSubscriptionSummary()
        }
        .task(id: appStoreConfigurationTaskID) {
            await refreshAppStoreConfiguration()
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
        GeometryReader { geometry in
            switch PublishingWindowLayout(width: geometry.size.width) {
            case .threeColumns:
                HStack(alignment: .top, spacing: 16) {
                    publishingColumn {
                        applicationSection(project)
                        actionPicker
                        localPublishSummary(project)
                    }
                    publishingColumn {
                        appStoreConnectOptions
                    }
                    publishingColumn {
                        selectedActionOptions
                    }
                }
            case .twoColumns:
                HStack(alignment: .top, spacing: 16) {
                    publishingColumn {
                        applicationSection(project)
                        actionPicker
                        localPublishSummary(project)
                    }
                    publishingColumn {
                        appStoreConnectOptions
                        selectedActionOptions
                    }
                }
            case .singleColumn:
                publishingColumn {
                    applicationSection(project)
                    actionPicker
                    localPublishSummary(project)
                    appStoreConnectOptions
                    selectedActionOptions
                }
            }
        }
    }

    private func publishingColumn<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applicationSection(_ project: ManagedProject) -> some View {
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
                configurationEditorStartsWithAI = false
                selectedWorkspace = .configuration
            } label: {
                Label("Edit Full Publishing Configuration…", systemImage: "doc.badge.gearshape")
            }
            Button {
                configurationEditorStartsWithAI = true
                selectedWorkspace = .configuration
            } label: {
                Label("Generate Settings with OpenAI…", systemImage: "sparkles")
            }
        }
    }

    private var actionPicker: some View {
        Picker("Action", selection: $selectedAction) {
            Text("App Release").tag(PublishingAction.release)
            Text("Offer Codes").tag(PublishingAction.offerCodes)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var selectedActionOptions: some View {
        if selectedAction == .release {
            releaseOptions
        } else {
            offerCodeOptions
        }
    }

    @ViewBuilder
    private func localPublishSummary(_ project: ManagedProject) -> some View {
        Section("Publish Summary") {
            LabeledContent("Supported devices") {
                Text(verbatim: project.deviceCompatibilityDescription)
            }
            let connected = model.connectedDevices.filter(project.supports)
            LabeledContent("Connected compatible devices") {
                Text(verbatim: connected.isEmpty
                    ? L10n.text("None")
                    : connected.map { "\($0.name) (\($0.connectionDescription))" }.joined(separator: ", "))
                    .textSelection(.enabled)
            }

            if let preview = localPublishingPreview {
                let publication = preview.catalog.publication
                let application = preview.catalog.application
                LabeledContent("Metadata source") {
                    let configuredCount = publication?.localizations?.count ?? 0
                    Text(publication?.metadata == nil && configuredCount == 0
                        ? L10n.format(
                            "OpenAI generation for %d language(s)",
                            ProjectLocalizationDiscoveryService().discover(
                                project: project,
                                defaultLocale: publication?.locale
                                    ?? model.preferences.appStoreLocale
                                    ?? "en-US"
                            ).count
                        )
                        : L10n.format(
                            "Per-app editable metadata for %d language(s)",
                            max(configuredCount, 1)
                        ))
                }
                LabeledContent("Locale") {
                    selectableValue(publication?.locale ?? model.preferences.appStoreLocale)
                }
                LabeledContent("Detected app languages") {
                    Text(verbatim: ProjectLocalizationDiscoveryService().discover(
                        project: project,
                        defaultLocale: publication?.locale
                            ?? model.preferences.appStoreLocale
                            ?? "en-US"
                    ).joined(separator: ", "))
                    .textSelection(.enabled)
                }
                LabeledContent("Primary category") {
                    selectableValue(application?.primaryCategory ?? publication?.metadata?.primaryCategory)
                }
                LabeledContent("Secondary category") {
                    selectableValue(application?.secondaryCategory ?? publication?.metadata?.secondaryCategory)
                }
                LabeledContent("Support URL") {
                    selectableValue(publication?.supportURL ?? model.preferences.appStoreSupportURL)
                }
                LabeledContent("Marketing URL") {
                    selectableValue(publication?.marketingURL)
                }
                LabeledContent("Privacy policy URL") {
                    selectableValue(publication?.privacyPolicyURL)
                }
                LabeledContent("Terms of Use URL") {
                    selectableValue(publication?.termsURL)
                }

                if let metadata = publication?.metadata {
                    DisclosureGroup("Editable Store Text") {
                        VStack(alignment: .leading, spacing: 10) {
                            metadataValue("App name", publication?.appName)
                            metadataValue("Subtitle", publication?.subtitle ?? metadata.subtitle)
                            metadataValue("Description", metadata.description)
                            metadataValue("Keywords", metadata.keywords)
                            metadataValue("Promotional text", metadata.promotionalText)
                            metadataValue("What’s New", metadata.whatsNew)
                        }
                        .padding(.vertical, 6)
                    }
                }
                if let localizations = publication?.localizations, !localizations.isEmpty {
                    DisclosureGroup(L10n.format("Localized Store Listings (%d)", localizations.count)) {
                        ForEach(localizations) { localization in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: localization.locale)
                                    .font(.headline)
                                metadataValue("App name", localization.appName)
                                metadataValue("Subtitle", localization.subtitle)
                                metadataValue("Description", localization.description)
                                metadataValue("Keywords", localization.keywords)
                                metadataValue("Promotional text", localization.promotionalText)
                                metadataValue("What’s New", localization.whatsNew)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }

                let productCount = preview.catalog.subscriptionCount
                DisclosureGroup(L10n.format("Local Subscriptions (%d)", productCount)) {
                    if preview.catalog.groups.isEmpty {
                        if preview.catalog.detectedProductIDs.isEmpty {
                            Text("No local subscriptions were detected.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.catalog.detectedProductIDs.sorted(), id: \.self) { productID in
                                Text(verbatim: productID)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            Text("Product identifiers were found in source files. Add duration, pricing, and group details in the Subscriptions tab before creating new products.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(preview.catalog.groups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: group.referenceName)
                                    .font(.subheadline.bold())
                                ForEach(group.subscriptions, id: \.productID) { subscription in
                                    Text(verbatim: "\(subscription.productID) · \(friendlyState(subscription.period)) · \(subscription.basePrice ?? "—") \(subscription.baseTerritory ?? "")")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.format(
                        "Screenshot Devices (%d)",
                        preview.screenshotPreview.devices.count
                    ))
                    .font(.subheadline.bold())

                    if preview.screenshotPreview.devices.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Detecting supported screenshot devices and installed Simulators…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(preview.screenshotPreview.devices) { device in
                            screenshotDeviceRow(device)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.format(
                        "Screenshot Preview (%d)",
                        preview.screenshotPreview.screenshots.count
                    ))
                    .font(.subheadline.bold())

                    if preview.screenshotPreview.screenshots.isEmpty {
                        Label(
                            "Screenshots are being extracted automatically from every supported Simulator family.",
                            systemImage: "camera.viewfinder"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(preview.screenshotPreview.screenshots, id: \.url) { screenshot in
                                screenshotPreviewCard(screenshot)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Inspecting local metadata, screenshots, and subscriptions…")
                        .foregroundStyle(.secondary)
                }
            }
            Label(
                "Apple still requires the initial app record, contracts, tax/banking, trader status, and App Privacy questionnaire to be completed in App Store Connect because those actions are not exposed by the API.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func screenshotDeviceRow(_ device: AppStoreScreenshotCaptureDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.platform.symbolName)
                .frame(width: 22)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.platform.title)
                    .fontWeight(.medium)
                if let name = device.name {
                    Text(verbatim: [name, device.runtime].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch device.state {
            case .provided:
                Label("Provided", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .ready:
                Label("Queued", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .capturing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Capturing…")
                }
            case .captured:
                Label("Captured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable:
                Label("Runtime unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed(let message):
                Label("Capture failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
        .padding(.vertical, 3)
    }

    private func screenshotPreviewCard(_ screenshot: AppStoreScreenshotAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOf: screenshot.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 230)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            Label(screenshot.platform.title, systemImage: screenshot.platform.symbolName)
                .font(.caption.bold())
            if let deviceName = screenshot.deviceName {
                Text(verbatim: deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: friendlyState(screenshot.displayType))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var appStoreConnectOptions: some View {
        Section("Current App Store Connect") {
            switch appStoreConfiguration {
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading the current App Store Connect configuration…")
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                HStack {
                    Button("Publishing Settings…") { openSettings() }
                    Button("Try Again") {
                        Task { await refreshAppStoreConfiguration() }
                    }
                }
            case .loaded(let snapshot):
                HStack {
                    Label("Live settings", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(snapshot.loadedAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await refreshAppStoreConfiguration() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                LabeledContent("Registered name") {
                    selectableValue(snapshot.appName)
                }
                LabeledContent("SKU") {
                    selectableValue(snapshot.sku)
                }
                LabeledContent("Primary locale") {
                    selectableValue(snapshot.primaryLocale)
                }
                LabeledContent("Primary category") {
                    selectableValue(snapshot.primaryCategory)
                }
                LabeledContent("Secondary category") {
                    selectableValue(snapshot.secondaryCategory)
                }
                LabeledContent("Content rights") {
                    selectableValue(snapshot.contentRightsDeclaration)
                }
                LabeledContent("Custom license territories") {
                    selectableValue(snapshot.licenseTerritoryIDs.isEmpty
                        ? nil
                        : L10n.format("%d territories", snapshot.licenseTerritoryIDs.count))
                }
                if snapshot.licenseAgreementText?.nilIfEmpty != nil {
                    DisclosureGroup("Custom License Agreement") {
                        Text(verbatim: snapshot.licenseAgreementText ?? "")
                            .textSelection(.enabled)
                            .padding(.vertical, 5)
                    }
                }
                if let ageRating = snapshot.ageRating, !ageRating.isEmpty {
                    DisclosureGroup("Age Rating Declaration") {
                        ForEach(ageRating.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(verbatim: friendlyState(key))
                                Spacer()
                                Text(verbatim: manifestValueText(ageRating[key]))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if !snapshot.appLocalizations.isEmpty {
                    DisclosureGroup("Localized App Information") {
                        ForEach(snapshot.appLocalizations) { localization in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: localization.locale)
                                    .font(.headline)
                                metadataValue("Name", localization.name)
                                metadataValue("Subtitle", localization.subtitle)
                                metadataValue("Privacy policy URL", localization.privacyPolicyURL)
                                metadataValue("Privacy choices URL", localization.privacyChoicesURL)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }

        if case .loaded(let snapshot) = appStoreConfiguration {
            Section("Version and Review Status") {
                if let version = snapshot.version {
                    HStack {
                        Text("Status")
                        Spacer()
                        statusLabel(version.state)
                    }
                    LabeledContent("App Store version") {
                        selectableValue(version.versionString)
                    }
                    LabeledContent("Uploaded build") {
                        selectableValue(version.buildNumber)
                    }
                    LabeledContent("Release method") {
                        selectableValue(version.releaseType.map(friendlyState))
                    }
                    LabeledContent("Copyright") {
                        selectableValue(version.copyright)
                    }
                    LabeledContent("Earliest release") {
                        selectableValue(version.earliestReleaseDate)
                    }

                    if version.localizations.isEmpty {
                        Text("No version localizations were returned.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(version.localizations) { localization in
                            DisclosureGroup(localization.locale) {
                                VStack(alignment: .leading, spacing: 10) {
                                    metadataValue("Description", localization.description)
                                    metadataValue("Keywords", localization.keywords)
                                    metadataValue("Promotional text", localization.promotionalText)
                                    metadataValue("What’s New", localization.whatsNew)
                                    metadataValue("Support URL", localization.supportURL)
                                    metadataValue("Marketing URL", localization.marketingURL)
                                    if localization.screenshotCounts.isEmpty {
                                        metadataValue("Screenshots", L10n.text("None"))
                                    } else {
                                        metadataValue(
                                            "Screenshots",
                                            localization.screenshotCounts
                                                .sorted(by: { $0.key < $1.key })
                                                .map { "\(friendlyState($0.key)): \($0.value)" }
                                                .joined(separator: "\n")
                                        )
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }

                    if let review = version.review {
                        DisclosureGroup("App Review Details") {
                            VStack(alignment: .leading, spacing: 10) {
                                metadataValue(
                                    "Contact name",
                                    [review.contactFirstName, review.contactLastName]
                                        .compactMap { $0?.nilIfEmpty }
                                        .joined(separator: " ")
                                        .nilIfEmpty
                                )
                                metadataValue("Contact email", review.contactEmail)
                                metadataValue("Contact phone", review.contactPhone)
                                metadataValue("Review notes", review.notes)
                                metadataValue(
                                    "Demo account required",
                                    review.demoAccountRequired ? L10n.text("Yes") : L10n.text("No")
                                )
                                Text("Demo-account passwords are intentionally never displayed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } else {
                    Label("No iOS App Store version exists yet.", systemImage: "plus.app")
                        .foregroundStyle(.secondary)
                }
            }

            Section("App Store Connect Subscriptions") {
                if snapshot.subscriptionGroups.isEmpty {
                    Label("No subscriptions exist in App Store Connect.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.format(
                        "%d subscription group(s), %d product(s)",
                        snapshot.subscriptionGroups.count,
                        snapshot.subscriptionGroups.reduce(0) { $0 + $1.subscriptions.count }
                    ))
                    ForEach(snapshot.subscriptionGroups) { group in
                        subscriptionGroupView(group)
                    }
                }
            }
        }
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
            if currentVersionIsAlreadySubmitted, let version = currentAppStoreSnapshot?.version {
                Label(
                    L10n.format("Version %@ is already %@; no duplicate upload will be started.", version.versionString, friendlyState(version.state)),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.blue)
            }
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

    @ViewBuilder
    private func subscriptionGroupView(
        _ group: AppStoreConnectSubscriptionGroupSnapshot
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                metadataValue("Reference name", group.referenceName)
                metadataValue("Status", group.state.map(friendlyState))
                ForEach(group.localizations, id: \.locale) { localization in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: localization.locale)
                            .font(.subheadline.bold())
                        metadataValue("Name", localization.name)
                        metadataValue("Description", localization.description)
                    }
                }
                ForEach(group.subscriptions) { subscription in
                    DisclosureGroup(subscription.productID) {
                        VStack(alignment: .leading, spacing: 8) {
                            metadataValue("Reference name", subscription.referenceName)
                            metadataValue("Status", subscription.state.map(friendlyState))
                            metadataValue("Period", subscription.period.map(friendlyState))
                            metadataValue("Group level", subscription.groupLevel.map(String.init))
                            metadataValue(
                                "Family Sharing",
                                subscription.familySharable ? L10n.text("Enabled") : L10n.text("Disabled")
                            )
                            metadataValue("Review note", subscription.reviewNote)
                            metadataValue(
                                "Availability",
                                L10n.format(
                                    "%d territories; new territories %@",
                                    subscription.availableTerritoryIDs.count,
                                    subscription.availableInNewTerritories == true
                                        ? L10n.text("enabled")
                                        : L10n.text("disabled")
                                )
                            )

                            if !subscription.localizations.isEmpty {
                                DisclosureGroup("Subscription Localizations") {
                                    ForEach(subscription.localizations, id: \.locale) { localization in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: localization.locale)
                                                .font(.subheadline.bold())
                                            metadataValue("Name", localization.name)
                                            metadataValue("Description", localization.description)
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                            }

                            DisclosureGroup(L10n.format("Prices (%d)", subscription.prices.count)) {
                                if subscription.prices.isEmpty {
                                    Text("No current prices were returned.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(subscription.prices) { price in
                                        HStack {
                                            Text(verbatim: price.territory)
                                                .font(.system(.body, design: .monospaced))
                                            Spacer()
                                            Text(verbatim: [price.price, price.currency]
                                                .compactMap { $0?.nilIfEmpty }
                                                .joined(separator: " "))
                                                .textSelection(.enabled)
                                            if price.preserved {
                                                Text("Preserved")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }

                            if !subscription.offers.isEmpty {
                                DisclosureGroup(L10n.format("Offer Codes (%d)", subscription.offers.count)) {
                                    ForEach(subscription.offers) { offer in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(verbatim: offer.name)
                                                    .font(.subheadline.bold())
                                                Spacer()
                                                Text(offer.active ? "Active" : "Inactive")
                                                    .foregroundStyle(offer.active ? .green : .secondary)
                                            }
                                            metadataValue("Duration", offer.duration.map(friendlyState))
                                            metadataValue(
                                                "Eligible subscribers",
                                                offer.customerEligibilities.map(friendlyState).joined(separator: ", ")
                                            )
                                            metadataValue(
                                                "Production codes",
                                                "\(offer.productionCodeCount) / \(offer.totalNumberOfCodes)"
                                            )
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Text(verbatim: group.referenceName)
                Spacer()
                Text(L10n.format("%d product(s)", group.subscriptions.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func selectableValue(_ value: String?) -> some View {
        Text(verbatim: value?.nilIfEmpty ?? "—")
            .foregroundStyle(value?.nilIfEmpty == nil ? .secondary : .primary)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func metadataValue(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value?.nilIfEmpty ?? "—")
                .foregroundStyle(value?.nilIfEmpty == nil ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLabel(_ state: String) -> some View {
        Label(friendlyState(state), systemImage: statusSymbol(state))
            .foregroundStyle(statusColor(state))
    }

    private func statusSymbol(_ state: String) -> String {
        switch state {
        case "WAITING_FOR_REVIEW", "IN_REVIEW": "clock.badge.checkmark"
        case "READY_FOR_SALE", "PREORDER_READY_FOR_SALE": "checkmark.seal.fill"
        case let value where value.contains("REJECTED"): "xmark.octagon.fill"
        default: "circle.dotted"
        }
    }

    private func statusColor(_ state: String) -> Color {
        switch state {
        case "WAITING_FOR_REVIEW", "IN_REVIEW": .blue
        case "READY_FOR_SALE", "PREORDER_READY_FOR_SALE": .green
        case let value where value.contains("REJECTED"): .red
        default: .orange
        }
    }

    private func friendlyState(_ rawValue: String) -> String {
        rawValue
            .split(separator: "_")
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }

    private func manifestValueText(_ value: AppStoreManifestValue?) -> String {
        switch value {
        case .string(let value): value
        case .bool(let value): value ? L10n.text("Yes") : L10n.text("No")
        case .integer(let value): String(value)
        case .decimal(let value): String(value)
        case nil: "—"
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
                        selectedAction == .release ? publishButtonTitle : L10n.text("Generate Codes"),
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
            localPublishingPreview = nil
            return
        }
        subscriptionSummary = .loading
        do {
            let catalog = try StoreKitSubscriptionDiscoveryService().discover(
                project: project,
                defaultLocale: model.preferences.appStoreLocale?.nilIfEmpty ?? "en-US"
            )
            let screenshotService = AppStorePublishingService()
            let localScreenshots = screenshotService.localScreenshotAssets(
                project: project,
                configuredPaths: catalog.publication?.screenshotPaths ?? []
            )
            localPublishingPreview = LocalPublishingPreview(
                catalog: catalog,
                screenshotPreview: AppStoreScreenshotPreview(
                    devices: [],
                    screenshots: localScreenshots
                )
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

            do {
                let projectID = project.id
                let prepared = try await screenshotService.prepareScreenshotPreview(
                    project: project,
                    configuredPaths: catalog.publication?.screenshotPaths ?? [],
                    onUpdate: { updated in
                        Task { @MainActor in
                            guard selectedProjectID == projectID,
                                  var current = localPublishingPreview
                            else {
                                return
                            }
                            current.screenshotPreview = updated
                            localPublishingPreview = current
                        }
                    }
                )
                guard selectedProjectID == project.id,
                      var current = localPublishingPreview
                else {
                    return
                }
                current.screenshotPreview = prepared
                localPublishingPreview = current
            } catch is CancellationError {
                return
            } catch {
                guard var current = localPublishingPreview else { return }
                let platforms = screenshotService.supportedScreenshotPlatforms(for: project)
                current.screenshotPreview = AppStoreScreenshotPreview(
                    devices: AppStoreScreenshotPlatform.allCases
                        .filter(platforms.contains)
                        .map {
                            AppStoreScreenshotCaptureDevice(
                                platform: $0,
                                name: nil,
                                runtime: nil,
                                state: .failed(error.localizedDescription)
                            )
                        },
                    screenshots: localScreenshots
                )
                localPublishingPreview = current
            }
        } catch {
            localPublishingPreview = nil
            subscriptionSummary = .error(error.localizedDescription)
        }
    }

    private func refreshAppStoreConfiguration() async {
        guard let projectID = selectedProjectID else {
            appStoreConfiguration = .error(L10n.text("Select an application."))
            return
        }
        appStoreConfiguration = .loading
        do {
            appStoreConfiguration = .loaded(
                try await model.loadAppStoreConnectConfiguration(projectID: projectID)
            )
        } catch is CancellationError {
            return
        } catch {
            appStoreConfiguration = .error(error.localizedDescription)
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

    private enum AppStoreConfigurationState: Equatable {
        case loading
        case loaded(AppStoreConnectConfigurationSnapshot)
        case error(String)
    }

    private struct LocalPublishingPreview: Equatable {
        let catalog: AppStoreSubscriptionCatalog
        var screenshotPreview: AppStoreScreenshotPreview
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

    private var appStoreConfigurationTaskID: String {
        "app-store-\(configurationTaskID)"
    }

    private var currentAppStoreSnapshot: AppStoreConnectConfigurationSnapshot? {
        guard case .loaded(let snapshot) = appStoreConfiguration else { return nil }
        return snapshot
    }

    private var currentVersionIsAlreadySubmitted: Bool {
        guard let projectVersion = selectedProject?.marketingVersion,
              let version = currentAppStoreSnapshot?.version,
              version.versionString == projectVersion else { return false }
        return version.isUnderReview
    }

    private var publishButtonTitle: String {
        guard currentVersionIsAlreadySubmitted,
              let state = currentAppStoreSnapshot?.version?.state else {
            return L10n.text("Publish")
        }
        switch state {
        case "READY_FOR_SALE", "PREORDER_READY_FOR_SALE":
            return L10n.text("Already Published")
        default:
            return L10n.text("Already in Review")
        }
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
        guard project.bundleIdentifier?.isEmpty == false,
              !subscriptionSummary.hasError,
              currentAppStoreSnapshot != nil else {
            return false
        }
        if selectedAction == .release {
            return project.marketingVersion?.isEmpty == false
                && project.buildNumber?.isEmpty == false
                && !currentVersionIsAlreadySubmitted
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
    @EnvironmentObject private var model: AppModel

    let project: ManagedProject
    let defaults: AppPreferences
    let currentConfiguration: AppStoreConnectConfigurationSnapshot?
    let generateAIDraftOnOpen: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var selectedTab = ConfigurationTab.listing
    @State private var baseManifest: AppStorePublishingManifest?
    @State private var json = ""
    @State private var validationMessage: String?
    @State private var isLoading = true
    @State private var isGeneratingAI = false

    @State private var locale = "en-US"
    @State private var appName = ""
    @State private var subtitle = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var promotionalText = ""
    @State private var whatsNew = ""
    @State private var additionalLocalizations: [AppStoreLocalizedMetadata] = []
    @State private var detectedLocales: [String] = []
    @State private var useAIMetadata = true
    @State private var copyright = ""
    @State private var supportURL = ""
    @State private var marketingURL = ""
    @State private var termsURL = ""
    @State private var privacyPolicyURL = ""
    @State private var privacyChoicesURL = ""
    @State private var screenshotPaths = "Screenshots"
    @State private var replaceScreenshots = false

    @State private var primaryCategory = ""
    @State private var secondaryCategory = ""
    @State private var contentRights = ""
    @State private var configureCommercialSettings = false
    @State private var appIsFree = true
    @State private var appBaseTerritory = "USA"
    @State private var appAvailableEverywhere = true
    @State private var licenseAgreementText = ""

    @State private var reviewFirstName = ""
    @State private var reviewLastName = ""
    @State private var reviewPhone = ""
    @State private var reviewEmail = ""
    @State private var reviewNotes = ""
    @State private var demoAccountRequired = false
    @State private var submitForReview = true
    @State private var releaseAutomatically = true

    @State private var subscriptionBaseTerritory = ""
    @State private var subscriptionsAvailableEverywhere = true
    @State private var subscriptionReviewScreenshot = ""
    @State private var subscriptionGroupsJSON = "[]"

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
                if selectedTab == .listing {
                    Button {
                        Task { await generateAIDraft() }
                    } label: {
                        if isGeneratingAI {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Generate All Languages with OpenAI", systemImage: "sparkles")
                        }
                    }
                    .disabled(isLoading || isGeneratingAI)
                }
            }

            Text("Current App Store Connect values are loaded as the starting point. AI can generate an editable draft; nothing is uploaded until Publish is confirmed. Advanced JSON remains available for every API-specific field.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Configuration", selection: $selectedTab) {
                ForEach(ConfigurationTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if isLoading {
                Spacer()
                ProgressView("Loading configuration…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                configurationContent
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
                Button("Cancel") { onCancel() }
                Button("Validate and Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            load()
            if generateAIDraftOnOpen, validationMessage == nil {
                await generateAIDraft()
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (_, .advanced):
                syncJSONFromFields()
            case (.advanced, _):
                syncFieldsFromJSON()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
        switch selectedTab {
        case .listing:
            Form {
                Section("Localization") {
                    LabeledContent("Detected app languages") {
                        Text(verbatim: detectedLocales.joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                    TextField("Locale", text: $locale)
                    TextField("App name", text: $appName)
                    TextField("Subtitle", text: $subtitle)
                    Toggle("Generate metadata with OpenAI during Publish", isOn: $useAIMetadata)
                    Text("OpenAI generates a separate editable listing for every language detected in the app project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Store Description") {
                    configurationTextEditor("Description", text: $description, height: 130)
                    TextField("Keywords", text: $keywords)
                    TextField("Promotional text", text: $promotionalText)
                    configurationTextEditor("What’s New", text: $whatsNew, height: 80)
                }
                Section("Additional Localized Listings") {
                    if additionalLocalizations.isEmpty {
                        Text("No additional localized listing is configured.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(additionalLocalizations.indices, id: \.self) { index in
                        DisclosureGroup(additionalLocalizations[index].locale) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Locale", text: $additionalLocalizations[index].locale)
                                TextField("App name", text: $additionalLocalizations[index].appName)
                                TextField("Subtitle", text: $additionalLocalizations[index].subtitle)
                                configurationTextEditor(
                                    "Description",
                                    text: $additionalLocalizations[index].description,
                                    height: 110
                                )
                                TextField("Keywords", text: $additionalLocalizations[index].keywords)
                                TextField(
                                    "Promotional text",
                                    text: $additionalLocalizations[index].promotionalText
                                )
                                configurationTextEditor(
                                    "What’s New",
                                    text: $additionalLocalizations[index].whatsNew,
                                    height: 70
                                )
                                Button("Remove Localization", role: .destructive) {
                                    guard additionalLocalizations.indices.contains(index) else { return }
                                    additionalLocalizations.remove(at: index)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    Button {
                        additionalLocalizations.append(
                            AppStoreLocalizedMetadata(
                                locale: "en-US",
                                appName: appName,
                                subtitle: "",
                                description: "",
                                keywords: "",
                                promotionalText: "",
                                whatsNew: ""
                            )
                        )
                    } label: {
                        Label("Add Localization", systemImage: "plus")
                    }
                }
                Section("URLs and Rights") {
                    TextField("Support URL", text: $supportURL)
                    TextField("Marketing URL", text: $marketingURL)
                    TextField("Privacy policy URL", text: $privacyPolicyURL)
                    TextField("Privacy choices URL", text: $privacyChoicesURL)
                    TextField("Terms of Use URL", text: $termsURL)
                    TextField("Copyright", text: $copyright)
                }
                Section("Screenshots") {
                    configurationTextEditor("Paths (one file or folder per line)", text: $screenshotPaths, height: 80)
                    Toggle("Replace existing screenshots for matching device sizes", isOn: $replaceScreenshots)
                    Text("Relative paths are resolved from the app project. The Publish overview automatically extracts and previews missing screenshots on every supported Simulator family.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

        case .appSetup:
            Form {
                Section("Categories and Content") {
                    Picker("Primary category", selection: $primaryCategory) {
                        Text("Preserve / AI suggestion").tag("")
                        ForEach(Self.categoryIdentifiers, id: \.self) { category in
                            Text(friendlyCategory(category)).tag(category)
                        }
                    }
                    Picker("Secondary category", selection: $secondaryCategory) {
                        Text("None").tag("")
                        ForEach(Self.categoryIdentifiers, id: \.self) { category in
                            Text(friendlyCategory(category)).tag(category)
                        }
                    }
                    Picker("Third-party content rights", selection: $contentRights) {
                        Text("Preserve").tag("")
                        Text("Uses third-party content").tag("USES_THIRD_PARTY_CONTENT")
                        Text("Does not use third-party content").tag("DOES_NOT_USE_THIRD_PARTY_CONTENT")
                    }
                }
                Section("Pricing and Availability") {
                    Toggle("Configure app price and availability", isOn: $configureCommercialSettings)
                    Toggle("The app itself is free", isOn: $appIsFree)
                        .disabled(!configureCommercialSettings)
                    TextField("Base territory", text: $appBaseTerritory)
                        .disabled(!configureCommercialSettings)
                    Toggle("Available in all territories", isOn: $appAvailableEverywhere)
                        .disabled(!configureCommercialSettings)
                }
                Section("Custom End-User License Agreement") {
                    configurationTextEditor("Agreement text", text: $licenseAgreementText, height: 180)
                    Text("Apple’s API accepts agreement text, not a terms URL. The Terms of Use URL from Store Listing is also appended to the App Store description.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Age Ratings") {
                    Text("Age-rating answers remain fully editable in Advanced JSON under application.ageRating so new Apple questionnaire fields can be used without an app update.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

        case .review:
            Form {
                Section("App Review Contact") {
                    TextField("First name", text: $reviewFirstName)
                    TextField("Last name", text: $reviewLastName)
                    TextField("Phone", text: $reviewPhone)
                    TextField("Email", text: $reviewEmail)
                    configurationTextEditor("Review notes", text: $reviewNotes, height: 100)
                    Toggle("A demo account is required", isOn: $demoAccountRequired)
                    Text("Demo credentials are managed in Publishing Settings and stored only in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Submission") {
                    Toggle("Submit the uploaded version for App Review", isOn: $submitForReview)
                    Toggle("Release automatically after Apple approves it", isOn: $releaseAutomatically)
                        .disabled(!submitForReview)
                }
            }
            .formStyle(.grouped)

        case .subscriptions:
            Form {
                Section("Subscription Defaults") {
                    TextField("Base territory", text: $subscriptionBaseTerritory)
                    Toggle("Available in all territories", isOn: $subscriptionsAvailableEverywhere)
                    TextField("Default review screenshot", text: $subscriptionReviewScreenshot)
                }
                Section("Groups and Products") {
                    configurationTextEditor("Subscription configuration JSON", text: $subscriptionGroupsJSON, height: 390)
                    Text("Edit reference names, product IDs, duration, base price, availability, Family Sharing, group level, review notes/screenshots, and every localization. Existing approved subscriptions are preserved for version-only releases unless their setup is part of a first publication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

        case .advanced:
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
    }

    private func configurationTextEditor(
        _ title: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: height)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var configurationURL: URL {
        project.folderURL.appendingPathComponent("app-store-publishing.json")
    }

    private func load() {
        defer { isLoading = false }
        do {
            detectedLocales = ProjectLocalizationDiscoveryService().discover(
                project: project,
                defaultLocale: defaults.appStoreLocale?.nilIfEmpty ?? "en-US"
            )
            var manifest: AppStorePublishingManifest
            let hasSavedConfiguration = FileManager.default.fileExists(atPath: configurationURL.path)
            if hasSavedConfiguration {
                let data = try Data(contentsOf: configurationURL)
                manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: data)
            } else {
                let catalog = try StoreKitSubscriptionDiscoveryService().discover(
                    project: project,
                    defaultLocale: defaults.appStoreLocale?.nilIfEmpty ?? "en-US"
                )
                let firstSubscription = catalog.groups.first?.subscriptions.first
                manifest = AppStorePublishingManifest(
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
            }
            mergeCurrentConfiguration(
                into: &manifest,
                preferCurrentValues: !hasSavedConfiguration
            )
            baseManifest = manifest
            loadFields(from: manifest)
            json = try Self.encoded(manifest)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func mergeCurrentConfiguration(
        into manifest: inout AppStorePublishingManifest,
        preferCurrentValues: Bool
    ) {
        guard let currentConfiguration else { return }
        var publication = manifest.publication ?? defaultPublicationConfiguration()
        let activeLocale = (preferCurrentValues ? currentConfiguration.primaryLocale?.nilIfEmpty : nil)
            ?? publication.locale?.nilIfEmpty
            ?? currentConfiguration.primaryLocale?.nilIfEmpty
            ?? "en-US"
        publication.locale = activeLocale
        let appLocalization = currentConfiguration.appLocalizations.first(where: { $0.locale == activeLocale })
            ?? currentConfiguration.appLocalizations.first
        let versionLocalization = currentConfiguration.version?.localizations.first(where: { $0.locale == activeLocale })
            ?? currentConfiguration.version?.localizations.first
        publication.appName = (preferCurrentValues ? appLocalization?.name?.nilIfEmpty : nil)
            ?? publication.appName?.nilIfEmpty
            ?? appLocalization?.name?.nilIfEmpty
            ?? currentConfiguration.appName
        publication.subtitle = (preferCurrentValues ? appLocalization?.subtitle?.nilIfEmpty : nil)
            ?? publication.subtitle?.nilIfEmpty
            ?? appLocalization?.subtitle?.nilIfEmpty
        publication.privacyPolicyURL = (preferCurrentValues ? appLocalization?.privacyPolicyURL?.nilIfEmpty : nil)
            ?? publication.privacyPolicyURL?.nilIfEmpty
            ?? appLocalization?.privacyPolicyURL?.nilIfEmpty
        publication.privacyChoicesURL = (preferCurrentValues ? appLocalization?.privacyChoicesURL?.nilIfEmpty : nil)
            ?? publication.privacyChoicesURL?.nilIfEmpty
            ?? appLocalization?.privacyChoicesURL?.nilIfEmpty
        publication.supportURL = (preferCurrentValues ? versionLocalization?.supportURL?.nilIfEmpty : nil)
            ?? publication.supportURL?.nilIfEmpty
            ?? versionLocalization?.supportURL?.nilIfEmpty
        publication.marketingURL = (preferCurrentValues ? versionLocalization?.marketingURL?.nilIfEmpty : nil)
            ?? publication.marketingURL?.nilIfEmpty
            ?? versionLocalization?.marketingURL?.nilIfEmpty
        publication.copyright = (preferCurrentValues ? currentConfiguration.version?.copyright?.nilIfEmpty : nil)
            ?? publication.copyright?.nilIfEmpty
            ?? currentConfiguration.version?.copyright?.nilIfEmpty
        publication.licenseAgreementText = publication.licenseAgreementText?.nilIfEmpty
            ?? currentConfiguration.licenseAgreementText?.nilIfEmpty
        if preferCurrentValues, let review = currentConfiguration.version?.review {
            publication.review = AppStoreReviewManifestConfiguration(
                contactFirstName: review.contactFirstName,
                contactLastName: review.contactLastName,
                contactPhone: review.contactPhone,
                contactEmail: review.contactEmail,
                notes: review.notes,
                demoAccountRequired: review.demoAccountRequired
            )
        }
        if preferCurrentValues, let releaseType = currentConfiguration.version?.releaseType {
            publication.releaseAutomatically = releaseType == "AFTER_APPROVAL"
        }
        if (publication.metadata == nil || preferCurrentValues), let versionLocalization {
            publication.metadata = AppStoreMetadata(
                description: versionLocalization.description ?? "",
                keywords: versionLocalization.keywords ?? "",
                promotionalText: versionLocalization.promotionalText ?? "",
                whatsNew: versionLocalization.whatsNew ?? "",
                subtitle: appLocalization?.subtitle,
                primaryCategory: currentConfiguration.primaryCategory,
                secondaryCategory: currentConfiguration.secondaryCategory
            )
        }
        if (publication.localizations?.isEmpty != false || preferCurrentValues),
           let versionLocalizations = currentConfiguration.version?.localizations,
           !versionLocalizations.isEmpty {
            publication.localizations = versionLocalizations.map { localization in
                let localizedApp = currentConfiguration.appLocalizations.first(where: {
                    $0.locale.caseInsensitiveCompare(localization.locale) == .orderedSame
                })
                return AppStoreLocalizedMetadata(
                    locale: localization.locale,
                    appName: localizedApp?.name ?? currentConfiguration.appName,
                    subtitle: localizedApp?.subtitle ?? "",
                    description: localization.description ?? "",
                    keywords: localization.keywords ?? "",
                    promotionalText: localization.promotionalText ?? "",
                    whatsNew: localization.whatsNew ?? ""
                )
            }
        }
        manifest.publication = publication
        var application = manifest.application ?? AppStoreApplicationConfiguration(
            primaryCategory: nil,
            secondaryCategory: nil,
            contentRightsDeclaration: nil,
            isFree: nil,
            baseTerritory: nil,
            availableInAllTerritories: nil,
            ageRating: nil
        )
        application.primaryCategory = (preferCurrentValues ? currentConfiguration.primaryCategory?.nilIfEmpty : nil)
            ?? application.primaryCategory?.nilIfEmpty
            ?? currentConfiguration.primaryCategory
        application.secondaryCategory = (preferCurrentValues ? currentConfiguration.secondaryCategory?.nilIfEmpty : nil)
            ?? application.secondaryCategory?.nilIfEmpty
            ?? currentConfiguration.secondaryCategory
        application.contentRightsDeclaration = (preferCurrentValues ? currentConfiguration.contentRightsDeclaration?.nilIfEmpty : nil)
            ?? application.contentRightsDeclaration?.nilIfEmpty
            ?? currentConfiguration.contentRightsDeclaration
        if preferCurrentValues || application.ageRating?.isEmpty != false {
            application.ageRating = currentConfiguration.ageRating ?? application.ageRating
        }
        manifest.application = application

        if manifest.subscriptions?.groups?.isEmpty != false,
           !currentConfiguration.subscriptionGroups.isEmpty {
            let groups = currentConfiguration.subscriptionGroups.map { group in
                AppStoreSubscriptionGroupDefinition(
                    referenceName: group.referenceName,
                    localizations: group.localizations,
                    subscriptions: group.subscriptions.map { subscription in
                        AppStoreSubscriptionDefinition(
                            referenceName: subscription.referenceName,
                            productID: subscription.productID,
                            period: subscription.period ?? "",
                            basePrice: nil,
                            baseTerritory: nil,
                            availableInAllTerritories: subscription.availableInNewTerritories,
                            familySharable: subscription.familySharable,
                            groupLevel: subscription.groupLevel,
                            reviewNote: subscription.reviewNote,
                            reviewScreenshot: nil,
                            localizations: subscription.localizations
                        )
                    }
                )
            }
            manifest.subscriptions = AppStoreSubscriptionsConfiguration(
                baseTerritory: manifest.subscriptions?.baseTerritory,
                availableInAllTerritories: manifest.subscriptions?.availableInAllTerritories
                    ?? currentConfiguration.subscriptionGroups
                        .flatMap(\.subscriptions)
                        .allSatisfy { $0.availableInNewTerritories == true },
                reviewScreenshot: manifest.subscriptions?.reviewScreenshot,
                groups: groups
            )
        }
    }

    private func loadFields(from manifest: AppStorePublishingManifest) {
        let publication = manifest.publication ?? defaultPublicationConfiguration()
        locale = publication.locale ?? "en-US"
        appName = publication.appName ?? ""
        subtitle = publication.subtitle ?? publication.metadata?.subtitle ?? ""
        description = publication.metadata?.description ?? ""
        keywords = publication.metadata?.keywords ?? ""
        promotionalText = publication.metadata?.promotionalText ?? ""
        whatsNew = publication.metadata?.whatsNew ?? ""
        if let localizations = publication.localizations, !localizations.isEmpty {
            let primaryIndex = localizations.firstIndex(where: {
                $0.locale.caseInsensitiveCompare(locale) == .orderedSame
            }) ?? 0
            let primary = localizations[primaryIndex]
            locale = primary.locale
            appName = primary.appName
            subtitle = primary.subtitle
            description = primary.description
            keywords = primary.keywords
            promotionalText = primary.promotionalText
            whatsNew = primary.whatsNew
            additionalLocalizations = localizations.enumerated().compactMap { index, localization in
                index == primaryIndex ? nil : localization
            }
        } else {
            additionalLocalizations = []
        }
        useAIMetadata = publication.metadata == nil
            && publication.localizations?.isEmpty != false
        copyright = publication.copyright ?? ""
        supportURL = publication.supportURL ?? ""
        marketingURL = publication.marketingURL ?? ""
        termsURL = publication.termsURL ?? ""
        privacyPolicyURL = publication.privacyPolicyURL ?? ""
        privacyChoicesURL = publication.privacyChoicesURL ?? ""
        screenshotPaths = (publication.screenshotPaths ?? []).joined(separator: "\n")
        replaceScreenshots = publication.replaceScreenshots ?? false
        submitForReview = publication.submitForReview ?? true
        releaseAutomatically = publication.releaseAutomatically ?? true
        reviewFirstName = publication.review?.contactFirstName ?? ""
        reviewLastName = publication.review?.contactLastName ?? ""
        reviewPhone = publication.review?.contactPhone ?? ""
        reviewEmail = publication.review?.contactEmail ?? ""
        reviewNotes = publication.review?.notes ?? ""
        demoAccountRequired = publication.review?.demoAccountRequired ?? false

        let application = manifest.application
        primaryCategory = application?.primaryCategory ?? publication.metadata?.primaryCategory ?? ""
        secondaryCategory = application?.secondaryCategory ?? publication.metadata?.secondaryCategory ?? ""
        contentRights = application?.contentRightsDeclaration ?? ""
        configureCommercialSettings = application?.isFree != nil || application?.availableInAllTerritories != nil
        appIsFree = application?.isFree ?? true
        appBaseTerritory = application?.baseTerritory ?? "USA"
        appAvailableEverywhere = application?.availableInAllTerritories ?? true
        licenseAgreementText = publication.licenseAgreementText ?? ""

        subscriptionBaseTerritory = manifest.subscriptions?.baseTerritory ?? ""
        subscriptionsAvailableEverywhere = manifest.subscriptions?.availableInAllTerritories ?? true
        subscriptionReviewScreenshot = manifest.subscriptions?.reviewScreenshot ?? ""
        subscriptionGroupsJSON = (try? Self.encodedJSON(manifest.subscriptions?.groups ?? [])) ?? "[]"
    }

    private func makeManifest() throws -> AppStorePublishingManifest {
        var manifest = baseManifest ?? AppStorePublishingManifest(
            schemaVersion: 1,
            publication: nil,
            application: nil,
            subscriptions: nil
        )
        let metadata = useAIMetadata ? nil : AppStoreMetadata(
            description: description,
            keywords: keywords,
            promotionalText: promotionalText,
            whatsNew: whatsNew,
            subtitle: subtitle.nilIfEmpty,
            primaryCategory: primaryCategory.nilIfEmpty,
            secondaryCategory: secondaryCategory.nilIfEmpty
        )
        let localizations: [AppStoreLocalizedMetadata]? = if useAIMetadata {
            nil
        } else {
            [
                AppStoreLocalizedMetadata(
                    locale: locale,
                    appName: appName,
                    subtitle: subtitle,
                    description: description,
                    keywords: keywords,
                    promotionalText: promotionalText,
                    whatsNew: whatsNew
                )
            ] + additionalLocalizations
        }
        manifest.publication = AppStorePublicationConfiguration(
            locale: locale.nilIfEmpty,
            copyright: copyright.nilIfEmpty,
            supportURL: supportURL.nilIfEmpty,
            marketingURL: marketingURL.nilIfEmpty,
            termsURL: termsURL.nilIfEmpty,
            privacyPolicyURL: privacyPolicyURL.nilIfEmpty,
            privacyChoicesURL: privacyChoicesURL.nilIfEmpty,
            appName: appName.nilIfEmpty,
            subtitle: subtitle.nilIfEmpty,
            licenseAgreementText: licenseAgreementText.nilIfEmpty,
            submitForReview: submitForReview,
            releaseAutomatically: releaseAutomatically,
            metadata: metadata,
            localizations: localizations,
            screenshotPaths: screenshotPaths.split(whereSeparator: \.isNewline).map(String.init),
            replaceScreenshots: replaceScreenshots,
            review: AppStoreReviewManifestConfiguration(
                contactFirstName: reviewFirstName.nilIfEmpty,
                contactLastName: reviewLastName.nilIfEmpty,
                contactPhone: reviewPhone.nilIfEmpty,
                contactEmail: reviewEmail.nilIfEmpty,
                notes: reviewNotes.nilIfEmpty,
                demoAccountRequired: demoAccountRequired
            )
        )
        var application = manifest.application ?? AppStoreApplicationConfiguration(
            primaryCategory: nil,
            secondaryCategory: nil,
            contentRightsDeclaration: nil,
            isFree: nil,
            baseTerritory: nil,
            availableInAllTerritories: nil,
            ageRating: nil
        )
        application.primaryCategory = primaryCategory.nilIfEmpty
        application.secondaryCategory = secondaryCategory.nilIfEmpty
        application.contentRightsDeclaration = contentRights.nilIfEmpty
        application.isFree = configureCommercialSettings ? appIsFree : nil
        application.baseTerritory = configureCommercialSettings ? appBaseTerritory.nilIfEmpty : nil
        application.availableInAllTerritories = configureCommercialSettings ? appAvailableEverywhere : nil
        manifest.application = application

        let groupsData = Data(subscriptionGroupsJSON.utf8)
        let groups = try JSONDecoder().decode([AppStoreSubscriptionGroupDefinition].self, from: groupsData)
        manifest.subscriptions = AppStoreSubscriptionsConfiguration(
            baseTerritory: subscriptionBaseTerritory.nilIfEmpty,
            availableInAllTerritories: subscriptionsAvailableEverywhere,
            reviewScreenshot: subscriptionReviewScreenshot.nilIfEmpty,
            groups: groups.isEmpty ? nil : groups
        )
        return manifest
    }

    private func syncJSONFromFields() {
        do {
            json = try Self.encoded(makeManifest())
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func syncFieldsFromJSON() {
        do {
            let manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: Data(json.utf8))
            baseManifest = manifest
            loadFields(from: manifest)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func generateAIDraft() async {
        isGeneratingAI = true
        defer { isGeneratingAI = false }
        do {
            let generated = try await model.generateAppStoreMetadataDrafts(
                projectID: project.id,
                preferredLocale: locale
            )
            guard let primaryIndex = generated.localizations.firstIndex(where: {
                $0.locale.caseInsensitiveCompare(locale) == .orderedSame
            }) ?? generated.localizations.indices.first else {
                throw OpenAIStoreMetadataError.missingGeneratedText
            }
            let primary = generated.localizations[primaryIndex]
            locale = primary.locale
            appName = primary.appName
            subtitle = primary.subtitle
            description = primary.description
            keywords = primary.keywords
            promotionalText = primary.promotionalText
            whatsNew = primary.whatsNew
            additionalLocalizations = generated.localizations.enumerated().compactMap { index, localization in
                index == primaryIndex ? nil : localization
            }
            detectedLocales = generated.localizations.map(\.locale)
            if primaryCategory.isEmpty { primaryCategory = generated.primaryCategory }
            if secondaryCategory.isEmpty { secondaryCategory = generated.secondaryCategory }
            useAIMetadata = false
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let manifest: AppStorePublishingManifest
            if selectedTab == .advanced {
                manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: Data(json.utf8))
            } else {
                manifest = try makeManifest()
            }
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
        for (name, rawURL) in [
            ("publication.marketingURL", manifest.publication?.marketingURL),
            ("publication.termsURL", manifest.publication?.termsURL),
            ("publication.privacyPolicyURL", manifest.publication?.privacyPolicyURL),
            ("publication.privacyChoicesURL", manifest.publication?.privacyChoicesURL)
        ] {
            guard let rawURL = rawURL?.nilIfEmpty else { continue }
            guard let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                throw ConfigurationEditorError.invalid(L10n.format("%@ must be a valid HTTP or HTTPS URL.", name))
            }
        }
        if let metadata = manifest.publication?.metadata,
           metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigurationEditorError.invalid(L10n.text("Manual metadata requires a non-empty description."))
        }
        var locales: Set<String> = []
        for localization in manifest.publication?.localizations ?? [] {
            let normalizedLocale = localization.locale
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalizedLocale.isEmpty,
                  locales.insert(normalizedLocale).inserted else {
                throw ConfigurationEditorError.invalid(
                    L10n.text("Localized listings require non-empty, unique locale identifiers.")
                )
            }
            guard localization.description.nilIfEmpty != nil else {
                throw ConfigurationEditorError.invalid(
                    L10n.format("The %@ listing requires a non-empty description.", localization.locale)
                )
            }
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

    private static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func friendlyCategory(_ identifier: String) -> String {
        identifier.split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }

    private enum ConfigurationTab: CaseIterable {
        case listing
        case appSetup
        case review
        case subscriptions
        case advanced

        var title: String {
            switch self {
            case .listing: L10n.text("Store Listing")
            case .appSetup: L10n.text("App Setup")
            case .review: L10n.text("Review")
            case .subscriptions: L10n.text("Subscriptions")
            case .advanced: L10n.text("Advanced JSON")
            }
        }
    }

    private static let categoryIdentifiers = [
        "BOOKS", "BUSINESS", "DEVELOPER_TOOLS", "EDUCATION", "ENTERTAINMENT",
        "FINANCE", "FOOD_AND_DRINK", "GAMES", "GRAPHICS_AND_DESIGN",
        "HEALTH_AND_FITNESS", "LIFESTYLE", "MAGAZINES_AND_NEWSPAPERS",
        "MEDICAL", "MUSIC", "NAVIGATION", "NEWS", "PHOTO_AND_VIDEO",
        "PRODUCTIVITY", "REFERENCE", "SHOPPING", "SOCIAL_NETWORKING",
        "SPORTS", "TRAVEL", "UTILITIES", "WEATHER"
    ]

    private enum ConfigurationEditorError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            }
        }
    }
}
