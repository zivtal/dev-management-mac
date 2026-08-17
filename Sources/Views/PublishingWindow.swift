import AppKit
import SwiftUI

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

enum PublishingLocalizationAccordionPolicy {
    static let automaticExpansionLimit = 5

    static func initialExpandedIndex(itemCount: Int) -> Int? {
        (1...automaticExpansionLimit).contains(itemCount) ? 0 : nil
    }

    static func expandedIndex(
        afterRemoving removedIndex: Int,
        currentExpandedIndex: Int?,
        remainingItemCount: Int
    ) -> Int? {
        guard remainingItemCount > 0, let currentExpandedIndex else { return nil }
        if currentExpandedIndex == removedIndex {
            return min(removedIndex, remainingItemCount - 1)
        }
        return currentExpandedIndex > removedIndex
            ? currentExpandedIndex - 1
            : currentExpandedIndex
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

enum PublishingAction: Hashable {
    case release
    case offerCodes
}

fileprivate enum PublishingConfigurationTab: CaseIterable {
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

private enum PublishingConfigurationEditorAnchor: Hashable {
    case appPrivacy
}

@MainActor
final class PublishingWindowPresenter {
    static let shared = PublishingWindowPresenter()

    private var windowController: NSWindowController?

    private init() {}

    func show(
        model: AppModel,
        projectID: UUID? = nil,
        action: PublishingAction = .release
    ) {
        windowController?.close()
        let loadingController = NSHostingController(
            rootView: PublishingWindowLoadingView(projectName: projectName(for: projectID, in: model))
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("Publish to the App Store")
        panel.contentViewController = loadingController
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
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

        Task { @MainActor [weak self, weak panel] in
            await Task.yield()
            guard let self,
                  let panel,
                  self.windowController?.window === panel
            else {
                return
            }
            let rootView = PublishingWindowView(
                initialProjectID: projectID,
                initialAction: action
            )
                .environmentObject(model)
            panel.contentViewController = NSHostingController(rootView: rootView)
        }
    }

    func close() {
        windowController?.close()
    }

    private func projectName(for projectID: UUID?, in model: AppModel) -> String? {
        guard let projectID else { return nil }
        return model.projects.first(where: { $0.id == projectID })?.displayName
    }
}

private struct PublishingWindowLoadingView: View {
    let projectName: String?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Opening Publish…")
                .font(.title2.weight(.semibold))
            Text(projectName.map { L10n.format("Preparing %@ for publishing…", $0) }
                ?? L10n.text("Preparing your applications for publishing…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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
    @State private var configurationEditorInitialTab = PublishingConfigurationTab.listing
    @State private var configurationEditorHighlightsMissingFields = false
    @State private var configurationSaveConfirmation: String?
    @State private var subscriptionPriceDrafts: [String: String] = [:]
    @State private var savedSubscriptionPrices: [String: String] = [:]
    @State private var subscriptionPriceSaveStatus: SubscriptionPriceSaveStatus?
    @State private var isSavingSubscriptionPrices = false
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
    @State private var expirationDate = SubscriptionOfferCodeExpiration.latestDate()
    @State private var codeStatus: CodeStatus?
    @State private var generatedRedeemCodes: [String] = []
    @State private var generatedCodesWereCopied = false
    @State private var generatedRedemptionURL: URL?
    @State private var redemptionLinkWasCopied = false
    @State private var oneTimeCodeSaveURL: URL?
    @State private var releaseAutomaticallySelection = true
    @State private var pendingPublishingIntent = PublishingIntent.publish
    @State private var showsPublicationStatus = false
    private let locksProjectSelection: Bool

    init(initialProjectID: UUID?, initialAction: PublishingAction = .release) {
        _selectedProjectID = State(initialValue: initialProjectID)
        _selectedAction = State(initialValue: initialAction)
        locksProjectSelection = initialProjectID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let log = presentedPublicationLog {
                PublishingProgressView(
                    log: log,
                    progress: model.publishingProgress,
                    onCancel: model.cancelPublishing,
                    onBackToReview: {
                        model.presentedError = nil
                        showsPublicationStatus = false
                        selectedProjectID = log.projectID
                        selectedWorkspace = .overview
                    },
                    onDone: {
                        model.presentedError = nil
                        PublishingWindowPresenter.shared.close()
                    }
                )
                .padding(-20)
            } else {
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
                        if let configurationSaveConfirmation {
                            Label(configurationSaveConfirmation, systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        PublishingReadinessView(
                            report: releaseReadinessReport(for: project),
                            target: L10n.format(
                                "%@ (%@)",
                                project.marketingVersion ?? "—",
                                project.buildNumber ?? "—"
                            ),
                            onEditApp: {
                                configurationSaveConfirmation = nil
                                configurationEditorStartsWithAI = false
                                configurationEditorInitialTab = firstConfigurationTabNeedingAttention
                                configurationEditorHighlightsMissingFields = true
                                selectedWorkspace = .configuration
                            },
                            onOpenSettings: openPublishingSettings
                        )
                        projectOptions(project)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        footer(project)
                    } else {
                        PerAppPublishingConfigurationEditor(
                            project: project,
                            defaults: model.preferences,
                            currentConfiguration: currentAppStoreSnapshot,
                            generateAIDraftOnOpen: configurationEditorStartsWithAI,
                            initialTab: configurationEditorInitialTab,
                            highlightMissingFields: configurationEditorHighlightsMissingFields,
                            onCancel: {
                                configurationEditorStartsWithAI = false
                                configurationEditorHighlightsMissingFields = false
                                selectedWorkspace = .overview
                            },
                            onSave: {
                                configurationRevision += 1
                                configurationEditorStartsWithAI = false
                                configurationEditorHighlightsMissingFields = false
                                configurationSaveConfirmation = L10n.text(
                                    "Publishing configuration saved. Release readiness was refreshed."
                                )
                                selectedWorkspace = .overview
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let log = model.publishingLog, log.state == .inProgress {
                selectedProjectID = log.projectID
                Task { @MainActor in
                    await Task.yield()
                    PublishingLogWindowPresenter.shared.show(model: model)
                    PublishingWindowPresenter.shared.close()
                }
            }
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
        .onChange(of: codeKind) { _, _ in
            clearGeneratedRedeemCodes()
            if !SubscriptionOfferCodeBatchSize.isValid(numberOfCodes) {
                numberOfCodes = 500
            }
        }
        .onChange(of: selectedProductID) { _, _ in
            clearGeneratedRedeemCodes()
        }
        .confirmationDialog(
            Text(releaseConfirmationTitle),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(releaseConfirmationActionTitle) {
                guard let projectID = selectedProjectID else { return }
                model.publish(
                    projectID: projectID,
                    intent: pendingPublishingIntent,
                    releaseAutomatically: releaseAutomatically,
                    replaceActiveReviewVersion: pendingPublishingIntent == .publish
                        && olderActiveReviewVersion != nil,
                    existingConfiguration: currentAppStoreSnapshot
                )
                if model.publishingProgress != nil {
                    PublishingLogWindowPresenter.shared.show(model: model)
                    PublishingWindowPresenter.shared.close()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(releaseConfirmationMessage)
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
            .disabled(locksProjectSelection)
            Picker(
                "App Store Connect API",
                selection: appStoreConnectCredentialProfileBinding(for: project)
            ) {
                Text("Default API").tag(Optional<UUID>.none)
                ForEach(model.preferences.appStoreConnectCredentialProfiles ?? []) { profile in
                    Text(profile.name.nilIfEmpty ?? L10n.text("Unnamed API"))
                        .tag(Optional(profile.id))
                }
            }
            LabeledContent("Bundle identifier", value: project.bundleIdentifier ?? L10n.text("Unknown"))
            LabeledContent("Version", value: project.marketingVersion ?? L10n.text("Unknown"))
            LabeledContent("Build", value: project.buildNumber ?? L10n.text("Unknown"))
            Button {
                configurationSaveConfirmation = nil
                configurationEditorStartsWithAI = false
                configurationEditorInitialTab = .listing
                configurationEditorHighlightsMissingFields = false
                selectedWorkspace = .configuration
            } label: {
                Label("Edit Full Publishing Configuration…", systemImage: "doc.badge.gearshape")
            }
            Button {
                configurationSaveConfirmation = nil
                configurationEditorStartsWithAI = true
                configurationEditorInitialTab = .listing
                configurationEditorHighlightsMissingFields = false
                selectedWorkspace = .configuration
            } label: {
                Label("Generate Settings with OpenAI…", systemImage: "sparkles")
            }
        }
    }

    private func appStoreConnectCredentialProfileBinding(
        for project: ManagedProject
    ) -> Binding<UUID?> {
        Binding(
            get: { project.appStoreConnectCredentialProfileID },
            set: { profileID in
                model.setAppStoreConnectCredentialProfile(profileID, for: project.id)
                configurationRevision += 1
            }
        )
    }

    private var actionPicker: some View {
        Picker("Action", selection: $selectedAction) {
            Text("Subscriptions").tag(PublishingAction.release)
            Text("Redeem Codes").tag(PublishingAction.offerCodes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var selectedActionOptions: some View {
        Section("Manage") {
            actionPicker
        }
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
                "Apple still requires the initial app record, contracts, tax/banking, trader status, collected-data App Privacy details, and the first-ever subscription submission in App Store Connect. No-data privacy declarations and later releases are automated here after authorization.",
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
                    Button("Publishing Settings…") { openPublishingSettings() }
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
            if let groups = localPublishingPreview?.catalog.groups, !groups.isEmpty {
                SubscriptionPricingCardsView(
                    groups: groups,
                    prices: $subscriptionPriceDrafts,
                    hasChanges: subscriptionPriceDrafts != savedSubscriptionPrices,
                    isSaving: isSavingSubscriptionPrices,
                    saveStatus: subscriptionPriceSaveStatus,
                    onSave: saveSubscriptionPrices
                )
            }
            Text("For a first publication, local .storekit files and app-store-publishing.json are reconciled with App Store Connect. If an older version is already published, these resources are preserved and only the new version is uploaded and submitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Submission") {
            Toggle("Release automatically after Apple approves it", isOn: $releaseAutomaticallySelection)
            Text("Both actions synchronize the complete App Store and TestFlight setup. Publish additionally submits the app version and subscription versions together for App Review; Upload to TestFlight stops immediately before submission.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !showsAppStoreReleaseAction {
                Label(
                    "For the first release, upload this build to TestFlight first. Submit for Review appears after Apple finishes processing the matching build.",
                    systemImage: "airplane.circle"
                )
                .foregroundStyle(.blue)
            }
            if let build = matchingTestFlightBuild {
                Label(
                    L10n.format("TestFlight already has version %@ (%@). Publish will reuse it without another archive or upload.", build.version, build.buildNumber),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.blue)
            }
            if currentVersionIsAlreadySubmitted, let version = currentAppStoreSnapshot?.version {
                Label(
                    L10n.format("Version %@ is already %@; no duplicate upload will be started.", version.versionString, friendlyState(version.state)),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.blue)
            } else if let active = olderActiveReviewVersion {
                Label(
                    L10n.format(
                        "Version %@ is %@. Update will ask before canceling that submission and replacing it with %@.",
                        active.versionString,
                        friendlyState(active.state),
                        selectedProject?.marketingVersion ?? L10n.text("the new version")
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var offerCodeOptions: some View {
        if generatedRedeemCodes.isEmpty {
            offerCodeForm
        } else {
            generatedRedeemCodeResult
        }
    }

    @ViewBuilder
    private var offerCodeForm: some View {
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

        if let eligibilityIssue = redeemCodeEligibilityIssue {
            Section("Availability") {
                Label("Redeem codes are not available yet", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(verbatim: eligibilityIssue)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Section("Existing Redeem Codes") {
                if let subscription = selectedLiveSubscription {
                    if subscription.offers.isEmpty {
                        Text("No redeem-code offers exist for this subscription yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(subscription.offers) { offer in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(verbatim: offer.name)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Label(
                                        offer.active ? L10n.text("Active") : L10n.text("Inactive"),
                                        systemImage: offer.active ? "checkmark.circle.fill" : "pause.circle.fill"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(offer.active ? .green : .secondary)
                                }
                                Text(L10n.format(
                                    "%d production code(s) · %d total redemption(s)",
                                    offer.productionCodeCount,
                                    offer.totalNumberOfCodes
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let duration = offer.duration {
                                    Text(verbatim: friendlyState(duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Text("Choose a subscription to view its current redeem codes.")
                        .foregroundStyle(.secondary)
                }
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
                        .labelsHidden()
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
                    : "Custom codes use letters and numbers only, up to 64 characters, with 500–25,000 redemptions per batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let codeStatus {
                    codeStatusView(codeStatus)
                }
                HStack {
                    Spacer()
                    Button {
                        handleGenerateCodesAction()
                    } label: {
                        if model.isGeneratingOfferCodes {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                codeKind == .oneTime ? "Generate Codes" : "Generate Redeem Code",
                                systemImage: "ticket.fill"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.hasActiveWork)
                }
            }
        }
    }

    @ViewBuilder
    private var generatedRedeemCodeResult: some View {
        Section(generatedRedeemCodes.count == 1 ? "Your Redeem Code" : "Your Redeem Codes") {
            ScrollView {
                Text(verbatim: generatedRedeemCodes.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: 320)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            Label(
                "Use the redemption link or your app’s StoreKit flow for a custom code. Apple may take up to one hour to activate it, and each Apple Account can redeem only one code from the same offer.",
                systemImage: "clock.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            if let generatedRedemptionURL {
                Text(verbatim: generatedRedemptionURL.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button {
                        copyGeneratedRedemptionLink()
                    } label: {
                        Label(
                            redemptionLinkWasCopied ? "Link Copied" : "Copy Redemption Link",
                            systemImage: redemptionLinkWasCopied ? "checkmark" : "link"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    Link("Open Redemption Page", destination: generatedRedemptionURL)
                }
            }
            Button {
                copyGeneratedRedeemCodes()
            } label: {
                Label(
                    generatedCodesWereCopied
                        ? L10n.text("Copied")
                        : L10n.text(generatedRedeemCodes.count == 1 ? "Copy Code" : "Copy All Codes"),
                    systemImage: generatedCodesWereCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            Button("Create Another Code") {
                clearGeneratedRedeemCodes()
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
                openPublishingSettings()
            }
            Spacer()
            Button("Cancel") {
                PublishingWindowPresenter.shared.close()
            }
            if selectedAction == .release {
                if showsAppStoreReleaseAction {
                    Button {
                        handleReleaseAction(project, intent: .testFlight)
                    } label: {
                        Label("Upload to TestFlight", systemImage: "airplane")
                    }
                    .disabled(model.hasActiveWork)
                    Button {
                        handleReleaseAction(project, intent: .publish)
                    } label: {
                        Label(
                            publishButtonTitle,
                            systemImage: "paperplane.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.hasActiveWork)
                } else {
                    Button {
                        handleReleaseAction(project, intent: .testFlight)
                    } label: {
                        Label("Upload to TestFlight", systemImage: "airplane")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.hasActiveWork)
                }
            }
        }
    }

    private var eligibleProjects: [ManagedProject] {
        model.projects.filter { !$0.isMacOSApplication && $0.installMethod == .xcodebuild }
    }

    private var selectedProject: ManagedProject? {
        guard let selectedProjectID else { return nil }
        return eligibleProjects.first(where: { $0.id == selectedProjectID })
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
            let configuredPrices = Dictionary(
                uniqueKeysWithValues: catalog.groups
                    .flatMap(\.subscriptions)
                    .map { ($0.productID, $0.basePrice ?? "") }
            )
            subscriptionPriceDrafts = configuredPrices
            savedSubscriptionPrices = configuredPrices
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

    private enum CodeStatus: Equatable {
        case success(String)
        case warning(String)
        case failure(String)
    }

    private var detectedProductIDs: [String] {
        guard case .found(let productIDs, _) = subscriptionSummary else { return [] }
        return productIDs
    }

    private var selectedLiveSubscription: AppStoreConnectSubscriptionSnapshot? {
        currentAppStoreSnapshot?.subscriptionGroups
            .flatMap(\.subscriptions)
            .first(where: { $0.productID == selectedProductID })
    }

    private var redeemCodeEligibilityIssue: String? {
        switch appStoreConfiguration {
        case .loading:
            return L10n.text("Checking whether this app can create production redeem codes…")
        case .error(let message):
            return message
        case .loaded(let snapshot):
            guard snapshot.hasReadyForDistributionVersion else {
                return L10n.text("Redeem codes become available after Apple approves and releases the app.")
            }
            guard let subscription = selectedLiveSubscription else {
                return L10n.text("Choose a subscription that exists in App Store Connect.")
            }
            guard subscription.state == "APPROVED" else {
                return L10n.format(
                    "The selected subscription must be Approved before redeem codes can be created. Current status: %@.",
                    subscription.state.map(friendlyState) ?? L10n.text("Unknown")
                )
            }
            return nil
        }
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

    private var matchingTestFlightBuild: AppStoreConnectBuildReference? {
        guard let project = selectedProject,
              let build = currentAppStoreSnapshot?.testFlightBuild,
              build.version == project.marketingVersion,
              build.buildNumber == project.buildNumber else { return nil }
        return build
    }

    private var presentedPublicationLog: PublishingLogSession? {
        guard let log = model.publishingLog,
              log.state == .inProgress || showsPublicationStatus else { return nil }
        return log
    }

    private func releaseReadinessReport(for project: ManagedProject) -> PublishingReadinessReport {
        PublishingReadinessReport(items: [
            sourceReadiness(for: project),
            accountReadiness,
            contentReadiness,
            complianceReadiness,
            screenshotReadiness,
            reviewReadiness
        ])
    }

    private func testFlightReadinessReport(for project: ManagedProject) -> PublishingReadinessReport {
        PublishingReadinessReport(items: [
            testFlightSourceReadiness(for: project),
            TestFlightReadinessPolicy.accountItem(
                credentialIsComplete: model.appStoreConnectCredentialIsComplete(for: project)
            ),
            contentReadiness,
            complianceReadiness,
            screenshotReadiness,
            reviewReadiness
        ])
    }

    private func testFlightSourceReadiness(
        for project: ManagedProject
    ) -> PublishingReadinessItem {
        guard let localVersion = project.marketingVersion?.nilIfEmpty,
              let localBuild = project.buildNumber?.nilIfEmpty else {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("Source version"),
                detail: L10n.text("The selected project does not provide a version and build number."),
                state: .blocked
            )
        }
        if currentVersionIsAlreadySubmitted, let remote = currentAppStoreSnapshot?.version {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("The App Store version is not editable"),
                detail: L10n.format(
                    "Version %@ is %@. Full TestFlight setup cannot change its listing until Apple returns it to an editable state.",
                    remote.versionString,
                    friendlyState(remote.state)
                ),
                state: .blocked
            )
        }
        if let build = matchingTestFlightBuild {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("Matching build is in TestFlight"),
                detail: L10n.format(
                    "%@ (%@) is already uploaded and will be reused.",
                    build.version,
                    build.buildNumber
                ),
                state: .ready
            )
        }
        return PublishingReadinessItem(
            id: "source",
            title: L10n.text("Source version is ready"),
            detail: L10n.format(
                "%@ (%@) is selected. The scheme may advance it once during archive.",
                localVersion,
                localBuild
            ),
            state: .ready
        )
    }

    private func sourceReadiness(for project: ManagedProject) -> PublishingReadinessItem {
        guard let localVersion = project.marketingVersion?.nilIfEmpty,
              let localBuild = project.buildNumber?.nilIfEmpty else {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("Source version"),
                detail: L10n.text("The selected project does not provide a version and build number."),
                state: .blocked
            )
        }
        if let remote = currentAppStoreSnapshot?.version,
           AppStoreVersionComparison.localArtifactIsOlder(
            localVersion: localVersion,
            localBuild: localBuild,
            remoteVersion: remote.versionString,
            remoteBuild: remote.buildNumber
           ) {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("Source checkout is out of date"),
                detail: L10n.format(
                    "Local %@ (%@) is older than App Store Connect %@ (%@). Update the selected checkout before publishing.",
                    localVersion,
                    localBuild,
                    remote.versionString,
                    remote.buildNumber ?? "—"
                ),
                state: .blocked
            )
        }
        if currentVersionIsAlreadySubmitted, let remote = currentAppStoreSnapshot?.version {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("This release is already with Apple"),
                detail: L10n.format(
                    "Version %@ (%@) is %@. Wait for Apple or advance the source version before another upload.",
                    remote.versionString,
                    remote.buildNumber ?? "—",
                    friendlyState(remote.state)
                ),
                state: .blocked
            )
        }
        if let active = olderActiveReviewVersion {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("A previous version is in review"),
                detail: L10n.format(
                    "Version %@ is %@. Update can cancel it and replace it with %@ after you confirm.",
                    active.versionString,
                    friendlyState(active.state),
                    localVersion
                ),
                state: .attention
            )
        }
        if let build = matchingTestFlightBuild {
            return PublishingReadinessItem(
                id: "source",
                title: L10n.text("Matching build is in TestFlight"),
                detail: L10n.format(
                    "%@ (%@) will be reused for Publish without another archive or upload.",
                    build.version,
                    build.buildNumber
                ),
                state: .ready
            )
        }
        return PublishingReadinessItem(
            id: "source",
            title: L10n.text("Source version is ready"),
            detail: L10n.format(
                "%@ (%@) is selected. The scheme may advance it once during archive.",
                localVersion,
                localBuild
            ),
            state: .ready
        )
    }

    private var accountReadiness: PublishingReadinessItem {
        switch appStoreConfiguration {
        case .loading:
            return PublishingReadinessItem(
                id: "account",
                title: L10n.text("App Store Connect access"),
                detail: L10n.text("Checking credentials and the live app record…"),
                state: .checking
            )
        case .error(let message):
            return PublishingReadinessItem(
                id: "account",
                title: L10n.text("App Store Connect needs attention"),
                detail: message,
                state: .blocked
            )
        case .loaded:
            let isComplete = selectedProject.map(model.appStoreConnectCredentialIsComplete) ?? false
            return PublishingReadinessItem(
                id: "account",
                title: L10n.text("App Store Connect is ready"),
                detail: isComplete
                    ? L10n.text("The API key works and the current app record was loaded.")
                    : L10n.text("Complete the API key configuration before publishing."),
                state: isComplete ? .ready : .blocked
            )
        }
    }

    private var contentReadiness: PublishingReadinessItem {
        guard let project = selectedProject, let preview = localPublishingPreview else {
            if case .error(let message) = subscriptionSummary {
                return PublishingReadinessItem(
                    id: "content",
                    title: L10n.text("Project content needs attention"),
                    detail: message,
                    state: .blocked
                )
            }
            return PublishingReadinessItem(
                id: "content",
                title: L10n.text("Store content"),
                detail: L10n.text("Inspecting metadata and subscription products…"),
                state: .checking
            )
        }
        let publication = preview.catalog.publication
        let hasManualMetadata = publication?.metadata != nil
            || publication?.localizations?.isEmpty == false
        guard hasManualMetadata else {
            return PublishingReadinessItem(
                id: "content",
                title: L10n.text("Store listing needs content"),
                detail: model.hasOpenAIAPIKey
                    ? L10n.text("Generate an editable draft with OpenAI, review it, and save it before releasing.")
                    : L10n.text("Add editable metadata or configure OpenAI to generate the listing."),
                state: .blocked
            )
        }
        let localeCount = max(
            publication?.localizations?.count ?? 0,
            ProjectLocalizationDiscoveryService().discover(
                project: project,
                defaultLocale: publication?.locale ?? model.preferences.appStoreLocale ?? "en-US"
            ).count
        )
        return PublishingReadinessItem(
            id: "content",
            title: L10n.text("Store content is ready"),
            detail: L10n.format(
                "%d language(s) and %d subscription product(s) will be reconciled.",
                localeCount,
                preview.catalog.subscriptionCount
            ),
            state: .ready
        )
    }

    private var screenshotReadiness: PublishingReadinessItem {
        guard let preview = localPublishingPreview else {
            return PublishingReadinessItem(
                id: "screenshots",
                title: L10n.text("Screenshots"),
                detail: L10n.text("Checking supplied assets and available simulators…"),
                state: .checking
            )
        }
        let screenshots = preview.screenshotPreview.screenshots.count
        let devices = preview.screenshotPreview.devices
        if screenshots == 0, devices.isEmpty {
            return PublishingReadinessItem(
                id: "screenshots",
                title: L10n.text("Screenshots"),
                detail: L10n.text("Detecting supported screenshot devices…"),
                state: .checking
            )
        }
        let canCapture = devices.contains { device in
            switch device.state {
            case .provided, .ready, .capturing, .captured: true
            case .unavailable, .failed: false
            }
        }
        guard screenshots > 0 || canCapture else {
            return PublishingReadinessItem(
                id: "screenshots",
                title: L10n.text("Screenshots need attention"),
                detail: L10n.text("No supplied screenshots or compatible simulator runtimes were found."),
                state: .blocked
            )
        }
        return PublishingReadinessItem(
            id: "screenshots",
            title: L10n.text("Screenshots are ready"),
            detail: screenshots > 0
                ? L10n.format("%d screenshot(s) are prepared; missing sizes will be captured automatically.", screenshots)
                : L10n.text("Compatible simulators are ready to capture every required device family."),
            state: .ready
        )
    }

    private var complianceReadiness: PublishingReadinessItem {
        guard let preview = localPublishingPreview else {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App declarations"),
                detail: L10n.text("Checking the saved App Store declarations…"),
                state: .checking
            )
        }
        let application = preview.catalog.application
        var missing: [String] = []
        if application?.primaryCategory?.nilIfEmpty == nil,
           currentAppStoreSnapshot?.primaryCategory?.nilIfEmpty == nil {
            missing.append(L10n.text("category"))
        }
        if application?.contentRightsDeclaration?.nilIfEmpty == nil,
           currentAppStoreSnapshot?.contentRightsDeclaration?.nilIfEmpty == nil {
            missing.append(L10n.text("content rights"))
        }
        if application?.isFree == nil {
            missing.append(L10n.text("free-download status"))
        }
        if !AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(application?.ageRating ?? [:]),
           !AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(currentAppStoreSnapshot?.ageRating ?? [:]) {
            missing.append(L10n.text("age rating"))
        }
        if !missing.isEmpty {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App declarations are incomplete"),
                detail: model.hasOpenAIAPIKey
                    ? L10n.format("Generate and review repository-backed answers for: %@.", missing.joined(separator: ", "))
                    : L10n.format("Missing: %@. Generate settings with OpenAI or edit App Setup.", missing.joined(separator: ", ")),
                state: .blocked
            )
        }
        let privacyState = AppStorePrivacyConfigurationPolicy.state(
            for: preview.catalog.compliance
        )
        guard privacyState != .missingDraft else {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App declarations are incomplete"),
                detail: L10n.text("Generate and review the App Privacy answers before publishing."),
                state: .blocked
            )
        }
        if privacyState == .confirmed {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App declarations are ready"),
                detail: L10n.text("Categories, rights, pricing, age rating, and the published App Privacy answers are saved."),
                state: .ready
            )
        }
        guard privacyState != .needsAutomaticAuthorization else {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App declarations need attention"),
                detail: L10n.text("Review and authorize automatic publishing of the App Privacy answers in App Setup."),
                state: .blocked
            )
        }
        guard privacyState != .needsManualConfirmation else {
            return PublishingReadinessItem(
                id: "compliance",
                title: L10n.text("App Privacy needs attention"),
                detail: L10n.text("Collected-data answers need purposes, linking, and tracking details. Publish them in App Store Connect, then record the manual confirmation."),
                state: .blocked
            )
        }
        guard model.preferences.appStorePrivacyAppleID?.nilIfEmpty != nil,
              model.hasAppStorePrivacyFastlaneSession,
              AppStorePrivacyPublishingService.executableURL() != nil else {
            return PublishingReadinessItem(
                id: "privacy-account",
                title: L10n.text("App Privacy automation needs attention"),
                detail: L10n.text("Add the publisher Apple ID and Fastlane session in Publishing Settings. Fastlane must also be installed."),
                state: .blocked
            )
        }
        return PublishingReadinessItem(
            id: "compliance",
            title: L10n.text("App declarations are ready"),
            detail: L10n.text("The reviewed no-data App Privacy answer will be published automatically before the release upload."),
            state: .ready
        )
    }

    private var reviewReadiness: PublishingReadinessItem {
        let publication = localPublishingPreview?.catalog.publication
        let requirements = reviewRequirements(publication: publication)
        guard requirements.contactIsComplete,
              requirements.supportURLIsComplete,
              requirements.privacyPolicyURLIsComplete,
              requirements.termsURLIsComplete,
              requirements.copyrightIsComplete else {
            var missing: [String] = []
            if !requirements.contactIsComplete {
                missing.append(L10n.text("review contact"))
            }
            if !requirements.supportURLIsComplete { missing.append(L10n.text("support URL")) }
            if !requirements.privacyPolicyURLIsComplete { missing.append(L10n.text("privacy policy")) }
            if !requirements.termsURLIsComplete { missing.append(L10n.text("Terms of Use")) }
            if !requirements.copyrightIsComplete { missing.append(L10n.text("copyright owner")) }
            return PublishingReadinessItem(
                id: "review",
                title: L10n.text("Review information is incomplete"),
                detail: L10n.format(
                    "Missing: %@. Open App Settings or Account Settings to complete it.",
                    missing.joined(separator: ", ")
                ),
                state: .blocked
            )
        }
        return PublishingReadinessItem(
            id: "review",
            title: L10n.text("App Review is ready"),
            detail: L10n.text("Review contact, manual support and legal URLs, and copyright are available."),
            state: .ready
        )
    }

    private func reviewRequirements(
        publication: AppStorePublicationConfiguration?
    ) -> (
        contactIsComplete: Bool,
        supportURLIsComplete: Bool,
        privacyPolicyURLIsComplete: Bool,
        termsURLIsComplete: Bool,
        copyrightIsComplete: Bool
    ) {
        let review = publication?.review
        let preferredLocale = publication?.locale?.nilIfEmpty
            ?? model.preferences.appStoreLocale?.nilIfEmpty
        let existing = currentAppStoreSnapshot?.publicationFallback(preferredLocale: preferredLocale)
        let contactValues = [
            review?.contactFirstName?.nilIfEmpty
                ?? model.preferences.appStoreReviewFirstName?.nilIfEmpty
                ?? existing?.review?.contactFirstName?.nilIfEmpty,
            review?.contactLastName?.nilIfEmpty
                ?? model.preferences.appStoreReviewLastName?.nilIfEmpty
                ?? existing?.review?.contactLastName?.nilIfEmpty,
            review?.contactPhone?.nilIfEmpty
                ?? model.preferences.appStoreReviewPhone?.nilIfEmpty
                ?? existing?.review?.contactPhone?.nilIfEmpty,
            review?.contactEmail?.nilIfEmpty
                ?? model.preferences.appStoreReviewEmail?.nilIfEmpty
                ?? existing?.review?.contactEmail?.nilIfEmpty
        ]
        let supportURL = publication?.supportURL?.nilIfEmpty
            ?? model.preferences.appStoreSupportURL?.nilIfEmpty
            ?? existing?.supportURL
        let copyright = publication?.copyright?.nilIfEmpty
            ?? model.preferences.appStoreCopyright?.nilIfEmpty
            ?? existing?.copyright
        let requiresTermsURL = (localPublishingPreview?.catalog.subscriptionCount ?? 0) > 0
        return (
            contactValues.allSatisfy { $0 != nil },
            supportURL != nil,
            publication?.privacyPolicyURL?.nilIfEmpty != nil,
            !requiresTermsURL || publication?.termsURL?.nilIfEmpty != nil,
            copyright != nil
        )
    }

    private var firstConfigurationTabNeedingAttention: PublishingConfigurationTab {
        let requirements = reviewRequirements(publication: localPublishingPreview?.catalog.publication)
        if !requirements.supportURLIsComplete
            || !requirements.privacyPolicyURLIsComplete
            || !requirements.termsURLIsComplete
            || !requirements.copyrightIsComplete {
            return .listing
        }
        if !requirements.contactIsComplete { return .review }
        if let application = localPublishingPreview?.catalog.application,
           application.primaryCategory?.nilIfEmpty == nil
            || application.contentRightsDeclaration?.nilIfEmpty == nil
            || application.isFree == nil
            || !AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(application.ageRating ?? [:]) {
            return .appSetup
        }
        if !AppStorePrivacyConfigurationPolicy.state(
            for: localPublishingPreview?.catalog.compliance
        ).allowsSaving {
            return .appSetup
        }
        if let selectedProject,
           releaseReadinessReport(for: selectedProject).blockers.contains(where: {
               $0.id == "content" || $0.id == "screenshots"
           }) {
            return .listing
        }
        return .review
    }

    private func handleReleaseAction(_ project: ManagedProject, intent: PublishingIntent) {
        let report = intent == .publish
            ? releaseReadinessReport(for: project)
            : testFlightReadinessReport(for: project)
        guard !report.isChecking else {
            model.presentedError = L10n.text("Release checks are still running. Please try again in a moment.")
            return
        }
        guard report.blockers.isEmpty else {
            let blockerIDs = Set(report.blockers.map(\.id))
            if blockerIDs.contains("privacy-account") {
                openPublishingSettings()
            } else if !blockerIDs.isDisjoint(with: ["review", "content", "compliance", "screenshots"]) {
                configurationEditorStartsWithAI = model.hasOpenAIAPIKey && needsEditableAIDraft
                configurationEditorInitialTab = firstConfigurationTabNeedingAttention
                configurationEditorHighlightsMissingFields = true
                selectedWorkspace = .configuration
            } else if blockerIDs.contains("account") {
                openPublishingSettings()
            } else {
                model.presentedError = report.blockers
                    .map { "\($0.title): \($0.detail)" }
                    .joined(separator: "\n\n")
            }
            return
        }
        pendingPublishingIntent = intent
        showsConfirmation = true
    }

    private func openPublishingSettings() {
        model.selectedSettingsSection = .publishing
        openSettings()
    }

    private var needsEditableAIDraft: Bool {
        guard let preview = localPublishingPreview else { return false }
        let publication = preview.catalog.publication
        let application = preview.catalog.application
        let listingIsMissing = publication?.metadata == nil
            && publication?.localizations?.isEmpty != false
        let answersAreMissing = application?.primaryCategory?.nilIfEmpty == nil
            || application?.contentRightsDeclaration?.nilIfEmpty == nil
            || application?.isFree == nil
            || !AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(application?.ageRating ?? [:])
        let copyrightIsMissing = reviewRequirements(publication: publication).copyrightIsComplete == false
        return listingIsMissing || answersAreMissing || copyrightIsMissing
    }

    private func saveSubscriptionPrices() {
        guard let preview = localPublishingPreview else { return }
        isSavingSubscriptionPrices = true
        defer { isSavingSubscriptionPrices = false }
        do {
            let normalized = try Dictionary(uniqueKeysWithValues: subscriptionPriceDrafts.map { productID, value in
                guard let price = SubscriptionPriceValidation.normalized(value) else {
                    throw SubscriptionPriceSaveError.invalidPrice(productID)
                }
                return (productID, price)
            })
            let configurationURL = selectedProject?.folderURL
                .appendingPathComponent("app-store-publishing.json")
            guard let configurationURL else { return }
            var manifest: AppStorePublishingManifest
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                manifest = try JSONDecoder().decode(
                    AppStorePublishingManifest.self,
                    from: Data(contentsOf: configurationURL)
                )
            } else {
                manifest = AppStorePublishingManifest(
                    schemaVersion: 1,
                    publication: preview.catalog.publication,
                    application: preview.catalog.application,
                    subscriptions: nil
                )
            }
            var groups = preview.catalog.groups
            for groupIndex in groups.indices {
                for subscriptionIndex in groups[groupIndex].subscriptions.indices {
                    let productID = groups[groupIndex].subscriptions[subscriptionIndex].productID
                    groups[groupIndex].subscriptions[subscriptionIndex].basePrice = normalized[productID]
                }
            }
            let existing = manifest.subscriptions
            manifest.subscriptions = AppStoreSubscriptionsConfiguration(
                baseTerritory: existing?.baseTerritory
                    ?? groups.flatMap(\.subscriptions).compactMap(\.baseTerritory).first,
                availableInAllTerritories: existing?.availableInAllTerritories
                    ?? groups.flatMap(\.subscriptions).allSatisfy { $0.availableInAllTerritories == true },
                familySharable: existing?.familySharable
                    ?? groups.flatMap(\.subscriptions).allSatisfy { $0.familySharable == true },
                reviewScreenshot: existing?.reviewScreenshot,
                groups: groups
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(manifest)
            data.append(0x0A)
            try data.write(to: configurationURL, options: .atomic)
            subscriptionPriceDrafts = normalized
            savedSubscriptionPrices = normalized
            subscriptionPriceSaveStatus = .success(
                L10n.text("Subscription prices were saved and will be applied during Publish.")
            )
            configurationRevision += 1
        } catch {
            subscriptionPriceSaveStatus = .failure(error.localizedDescription)
        }
    }

    private var currentVersionIsAlreadySubmitted: Bool {
        guard let projectVersion = selectedProject?.marketingVersion,
              let version = currentAppStoreSnapshot?.version,
              version.versionString == projectVersion else { return false }
        return version.isUnderReview
    }

    private var showsAppStoreReleaseAction: Bool {
        guard let snapshot = currentAppStoreSnapshot else { return false }
        return AppStoreReleaseActionPolicy.showsAppStoreAction(
            hasReleasedVersion: snapshot.hasReadyForDistributionVersion,
            hasMatchingTestFlightBuild: matchingTestFlightBuild != nil
        )
    }

    private var olderActiveReviewVersion: AppStoreConnectVersionReferenceSnapshot? {
        guard let localVersion = selectedProject?.marketingVersion?.nilIfEmpty,
              let active = currentAppStoreSnapshot?.activeReviewVersion,
              active.versionString != localVersion else { return nil }
        return active
    }

    private var publishButtonTitle: String {
        if currentVersionIsAlreadySubmitted,
           let state = currentAppStoreSnapshot?.version?.state {
            switch state {
            case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PREORDER_READY_FOR_SALE":
                return L10n.text("Already Published")
            default:
                return L10n.text("Already in Review")
            }
        }
        if matchingTestFlightBuild != nil, olderActiveReviewVersion == nil {
            return L10n.text("Submit for Review")
        }
        if currentAppStoreSnapshot?.hasReadyForDistributionVersion == true {
            return L10n.text("Update")
        }
        return L10n.text("Publish")
    }

    private var releaseConfirmationTitle: String {
        if pendingPublishingIntent == .testFlight {
            return L10n.text("Upload this build to TestFlight?")
        }
        if let active = olderActiveReviewVersion {
            return L10n.format("Replace version %@ in review?", active.versionString)
        }
        if matchingTestFlightBuild != nil {
            return L10n.text("Submit this version for App Review?")
        }
        return L10n.text(publishButtonTitle == L10n.text("Update")
            ? "Update on the App Store?"
            : "Publish to the App Store?")
    }

    private var releaseConfirmationActionTitle: String {
        if pendingPublishingIntent == .testFlight {
            return matchingTestFlightBuild == nil
                ? L10n.text("Build and upload to TestFlight")
                : L10n.text("Confirm TestFlight availability")
        }
        if let active = olderActiveReviewVersion {
            return L10n.format(
                "Cancel %@ and submit %@",
                active.versionString,
                selectedProject?.marketingVersion ?? L10n.text("the update")
            )
        }
        return matchingTestFlightBuild == nil
            ? L10n.text("Build, upload, and submit")
            : L10n.text("Submit to App Review")
    }

    private var releaseConfirmationMessage: String {
        if pendingPublishingIntent == .testFlight {
            return matchingTestFlightBuild == nil
                ? L10n.text("This action synchronizes the complete App Store listing, app setup, subscriptions, localized screenshots, beta information, internal testers, pricing, review details, and review attachments; then archives, uploads, processes, and assigns the build to TestFlight. It stops immediately before App Review submission.")
                : L10n.text("The exact build is already in TestFlight. Development Management will synchronize the complete App Store and TestFlight setup, reuse the build, and stop before App Review submission.")
        }
        if let active = olderActiveReviewVersion {
            return L10n.format(
                matchingTestFlightBuild == nil
                    ? "Apple allows one app version per platform in review. Continuing will first build the new app, then cancel version %@ and its submission items, replace it with %@, upload the build to TestFlight, and submit the replacement for review. The review queue starts over."
                    : "Apple allows one app version per platform in review. Continuing will cancel version %@ and its submission items, replace it with %@, reuse the matching TestFlight build, and submit the replacement for review. The review queue starts over.",
                active.versionString,
                selectedProject?.marketingVersion ?? L10n.text("the new version")
            )
        }
        return matchingTestFlightBuild == nil
            ? L10n.text("Publish synchronizes the complete localized listing, app declarations, free price and availability, subscriptions and territory prices, screenshots, TestFlight information, internal testers, and review details. It then archives and uploads the build, attaches review assets, and submits the app version plus subscription group and subscription versions together.")
            : L10n.text("The exact build is already in TestFlight. Publish will synchronize the complete App Store and TestFlight setup, reuse that build, attach review assets, and submit the app version plus subscription group and subscription versions together without another archive or upload.")
    }

    private var earliestExpirationDate: Date {
        SubscriptionOfferCodeExpiration.earliestDate()
    }

    private var latestExpirationDate: Date {
        SubscriptionOfferCodeExpiration.latestDate()
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

    private var offerCodeValidationIssue: String? {
        if let redeemCodeEligibilityIssue { return redeemCodeEligibilityIssue }
        guard selectedProject?.bundleIdentifier?.isEmpty == false,
              !subscriptionSummary.hasError,
              currentAppStoreSnapshot != nil,
              !selectedProductID.isEmpty else {
            return L10n.text("Choose an available App Store subscription.")
        }
        guard offerReferenceName.nilIfEmpty != nil else {
            return SubscriptionOfferCodeValidationError.missingReferenceName.localizedDescription
        }
        guard !offerEligibilities.isEmpty else {
            return SubscriptionOfferCodeValidationError.missingEligibility.localizedDescription
        }
        if codeKind == .oneTime || customHasExpiration,
           !SubscriptionOfferCodeExpiration.isValid(expirationDate) {
            return SubscriptionOfferCodeValidationError.invalidExpirationDate.localizedDescription
        }
        guard SubscriptionOfferCodeBatchSize.isValid(numberOfCodes) else {
            return SubscriptionOfferCodeValidationError.invalidBatchSize.localizedDescription
        }
        guard (1...64).contains(customCode.count),
              customCode.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            return SubscriptionOfferCodeValidationError.invalidCustomCode.localizedDescription
        }
        return nil
    }

    private func handleGenerateCodesAction() {
        if let issue = offerCodeValidationIssue {
            codeStatus = .failure(issue)
            return
        }
        if codeKind == .oneTime {
            let panel = NSSavePanel()
            panel.title = L10n.text("Save One-Time Offer Codes")
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(selectedProductID.replacingOccurrences(of: ".", with: "-"))-offer-codes.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            oneTimeCodeSaveURL = url
        } else {
            oneTimeCodeSaveURL = nil
        }
        showsCodeConfirmation = true
    }

    private func generateOfferCodes() async {
        guard let projectID = selectedProjectID else { return }
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
            if let csv = result.oneTimeCodeCSV, let oneTimeCodeSaveURL {
                do {
                    try csv.write(to: oneTimeCodeSaveURL, options: .atomic)
                } catch {
                    codeStatus = .failure(L10n.format(
                        "Batch %@ was created, but the CSV could not be saved: %@",
                        result.batchID,
                        error.localizedDescription
                    ))
                    return
                }
                codeStatus = .success(L10n.format(
                    "Generated %d codes and saved %@.",
                    numberOfCodes,
                    oneTimeCodeSaveURL.lastPathComponent
                ))
            } else if codeKind == .oneTime {
                codeStatus = .warning(L10n.format(
                    "The batch was created, but Apple is still preparing its CSV. Batch ID: %@",
                    result.batchID
                ))
            } else {
                generatedRedeemCodes = [result.customCode ?? customCode]
                generatedRedemptionURL = result.redemptionURL
            }
        } catch {
            codeStatus = .failure(error.localizedDescription)
        }
    }

    private func copyGeneratedRedeemCodes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedRedeemCodes.joined(separator: "\n"), forType: .string)
        generatedCodesWereCopied = true
    }

    private func copyGeneratedRedemptionLink() {
        guard let generatedRedemptionURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedRedemptionURL.absoluteString, forType: .string)
        redemptionLinkWasCopied = true
    }

    private func clearGeneratedRedeemCodes() {
        generatedRedeemCodes = []
        generatedCodesWereCopied = false
        generatedRedemptionURL = nil
        redemptionLinkWasCopied = false
        oneTimeCodeSaveURL = nil
        codeStatus = nil
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
    let initialTab: PublishingConfigurationTab
    let highlightMissingFields: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var selectedTab = PublishingConfigurationTab.listing
    @State private var baseManifest: AppStorePublishingManifest?
    @State private var json = ""
    @State private var validationMessage: String?
    @State private var isLoading = true
    @State private var isGeneratingAI = false
    @State private var isGeneratingAgeRating = false
    @State private var isGeneratingPrivacy = false
    @State private var aiGenerationNotice: String?
    @State private var showsRequiredFieldErrors = false
    @State private var pendingScrollAnchor: PublishingConfigurationEditorAnchor?
    @State private var scrollRequestRevision = 0

    @State private var locale = "en-US"
    @State private var appName = ""
    @State private var subtitle = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var promotionalText = ""
    @State private var whatsNew = ""
    @State private var additionalLocalizations: [AppStoreLocalizedMetadata] = []
    @State private var expandedAdditionalLocalizationIndex: Int?
    @State private var detectedLocales: [String] = []
    @State private var copyright = ""
    @State private var supportURL = ""
    @State private var marketingURL = ""
    @State private var termsURL = ""
    @State private var privacyPolicyURL = ""
    @State private var privacyChoicesURL = ""
    @State private var screenshotPaths = "Screenshots"
    @State private var reviewAttachmentPaths = ""
    @State private var replaceScreenshots = false

    @State private var primaryCategory = ""
    @State private var secondaryCategory = ""
    @State private var contentRights = ""
    @State private var ageRating: [String: AppStoreManifestValue] = [:]
    @State private var privacyDraftIsSpecified = false
    @State private var privacyCollectsData = false
    @State private var privacyDataTypes: [String] = []
    @State private var privacyNotes: [String] = []
    @State private var privacyConfirmedInAppStoreConnect = false
    @State private var privacyConfirmedManually = false
    @State private var privacyConfirmedBy = ""
    @State private var privacyConfirmedAt = ""
    @State private var complianceEvidence: [String] = []
    @State private var complianceConfidence: Double?
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
    @State private var releaseAutomatically = true
    @State private var testFlightGroupName = "Internal Testing"
    @State private var testFlightFeedbackEmail = ""
    @State private var testFlightReviewNotes = ""
    @State private var internalTesterEmails = ""

    @State private var subscriptionBaseTerritory = ""
    @State private var subscriptionsAvailableEverywhere = true
    @State private var subscriptionsFamilySharable = true
    @State private var subscriptionReviewScreenshot = ""
    @State private var subscriptionGroups: [PublishingSubscriptionGroupForm] = []

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
                            Label("Generate Listing and App Answers with OpenAI", systemImage: "sparkles")
                        }
                    }
                    .disabled(isLoading || isGeneratingAI || isGeneratingAgeRating || isGeneratingPrivacy)
                }
            }

            Text("Current App Store Connect values are loaded as the starting point. OpenAI analyzes the managed app’s first-party source repository to generate an editable listing, categories, rights, price/download, sign-in, age-rating, and App Privacy checklist. Each generation refreshes the age-rating and App Privacy drafts for review. Nothing is uploaded until a release action is confirmed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Configuration", selection: $selectedTab) {
                ForEach(PublishingConfigurationTab.allCases, id: \.self) { tab in
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
                ScrollViewReader { proxy in
                    configurationContent
                        .task(id: scrollRequestRevision) {
                            guard let pendingScrollAnchor else { return }
                            await Task.yield()
                            withAnimation {
                                proxy.scrollTo(pendingScrollAnchor, anchor: .top)
                            }
                        }
                }
            }

            if let aiGenerationNotice {
                Label(aiGenerationNotice, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                Button("Validate, Save, and Return") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isGeneratingAI || isGeneratingAgeRating || isGeneratingPrivacy)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            selectedTab = initialTab
            showsRequiredFieldErrors = highlightMissingFields
            load()
            if highlightMissingFields,
               selectedTab == .appSetup,
               privacyEditorValidationMessage != nil {
                revealAppPrivacySection()
            }
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
        GeometryReader { geometry in
            configurationContent(layout: PublishingWindowLayout(width: geometry.size.width))
        }
    }

    @ViewBuilder
    private func configurationContent(layout: PublishingWindowLayout) -> some View {
        switch selectedTab {
        case .listing:
            listingConfiguration(layout: layout)
        case .appSetup:
            appSetupConfiguration(layout: layout)
        case .review:
            reviewConfiguration(layout: layout)
        case .subscriptions:
            PublishingSubscriptionForm(
                baseTerritory: $subscriptionBaseTerritory,
                availableInAllTerritories: $subscriptionsAvailableEverywhere,
                familySharable: $subscriptionsFamilySharable,
                reviewScreenshot: $subscriptionReviewScreenshot,
                groups: $subscriptionGroups,
                territoryIDs: currentConfiguration?.territoryIDs ?? []
            )
        case .advanced:
            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                }
        }
    }

    @ViewBuilder
    private func listingConfiguration(layout: PublishingWindowLayout) -> some View {
        switch layout {
        case .threeColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    localizationSection
                    storeDescriptionSection
                }
                configurationForm {
                    additionalLocalizedListingsSection
                }
                configurationForm {
                    urlsAndRightsSection
                    screenshotsSection
                }
            }
        case .twoColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    localizationSection
                    storeDescriptionSection
                }
                configurationForm {
                    additionalLocalizedListingsSection
                    urlsAndRightsSection
                    screenshotsSection
                }
            }
        case .singleColumn:
            configurationForm {
                localizationSection
                storeDescriptionSection
                additionalLocalizedListingsSection
                urlsAndRightsSection
                screenshotsSection
            }
        }
    }

    @ViewBuilder
    private func appSetupConfiguration(layout: PublishingWindowLayout) -> some View {
        switch layout {
        case .threeColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    categoriesAndContentSection
                    pricingAndAvailabilitySection
                }
                configurationForm {
                    ageRatingsSection
                }
                configurationForm {
                    appPrivacySection
                    licenseAgreementSection
                }
            }
        case .twoColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    categoriesAndContentSection
                    pricingAndAvailabilitySection
                    ageRatingsSection
                }
                configurationForm {
                    appPrivacySection
                    licenseAgreementSection
                }
            }
        case .singleColumn:
            configurationForm {
                categoriesAndContentSection
                pricingAndAvailabilitySection
                ageRatingsSection
                appPrivacySection
                licenseAgreementSection
            }
        }
    }

    @ViewBuilder
    private func reviewConfiguration(layout: PublishingWindowLayout) -> some View {
        switch layout {
        case .threeColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    appReviewContactSection
                }
                configurationForm {
                    submissionSection
                    reviewAttachmentsSection
                }
                configurationForm {
                    testFlightSection
                }
            }
        case .twoColumns:
            HStack(alignment: .top, spacing: 16) {
                configurationForm {
                    appReviewContactSection
                    reviewAttachmentsSection
                }
                configurationForm {
                    submissionSection
                    testFlightSection
                }
            }
        case .singleColumn:
            configurationForm {
                appReviewContactSection
                submissionSection
                testFlightSection
                reviewAttachmentsSection
            }
        }
    }

    private func configurationForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var localizationSection: some View {
        Section("Localization") {
            LabeledContent("Detected app languages") {
                Text(verbatim: detectedLocales.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            TextField("Locale", text: $locale)
            TextField("App name", text: $appName)
            TextField("Subtitle", text: $subtitle)
            Text("OpenAI generates a separate editable draft for every language detected in the app project. Review and save the fields before releasing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storeDescriptionSection: some View {
        Section("Store Description") {
            configurationTextEditor("Description", text: $description, height: 130)
            TextField("Keywords", text: $keywords)
            TextField("Promotional text", text: $promotionalText)
            configurationTextEditor("What’s New", text: $whatsNew, height: 80)
        }
    }

    private var additionalLocalizedListingsSection: some View {
        Section("Additional Localized Listings") {
            if additionalLocalizations.isEmpty {
                Text("No additional localized listing is configured.")
                    .foregroundStyle(.secondary)
            }
            ForEach(additionalLocalizations.indices, id: \.self) { index in
                DisclosureGroup(
                    additionalLocalizations[index].locale,
                    isExpanded: additionalLocalizationExpansionBinding(for: index)
                ) {
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
                            removeAdditionalLocalization(at: index)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Button {
                addAdditionalLocalization()
            } label: {
                Label("Add Localization", systemImage: "plus")
            }
        }
    }

    private func additionalLocalizationExpansionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { expandedAdditionalLocalizationIndex == index },
            set: { isExpanded in
                if isExpanded {
                    expandedAdditionalLocalizationIndex = index
                } else if expandedAdditionalLocalizationIndex == index {
                    expandedAdditionalLocalizationIndex = nil
                }
            }
        )
    }

    private func addAdditionalLocalization() {
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
        expandedAdditionalLocalizationIndex = additionalLocalizations.indices.last
    }

    private func removeAdditionalLocalization(at index: Int) {
        guard additionalLocalizations.indices.contains(index) else { return }
        additionalLocalizations.remove(at: index)
        expandedAdditionalLocalizationIndex = PublishingLocalizationAccordionPolicy.expandedIndex(
            afterRemoving: index,
            currentExpandedIndex: expandedAdditionalLocalizationIndex,
            remainingItemCount: additionalLocalizations.count
        )
    }

    private var urlsAndRightsSection: some View {
        Section("URLs and Rights") {
            requiredTextField(
                "Support URL",
                text: $supportURL,
                validation: supportURLValidation
            )
            TextField("Marketing URL", text: $marketingURL)
            requiredTextField(
                "Privacy policy URL",
                text: $privacyPolicyURL,
                validation: privacyPolicyURLValidation
            )
            TextField("Privacy choices URL", text: $privacyChoicesURL)
            if requiresTermsURL {
                requiredTextField(
                    "Terms of Use URL",
                    text: $termsURL,
                    validation: termsURLValidation
                )
            } else {
                TextField("Terms of Use URL", text: $termsURL)
            }
            Text("OpenAI drafts listing copy and App Store answers from the managed app’s source repository. Support, marketing, privacy, and Terms of Use URLs are entered manually and are never replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            requiredTextField(
                "Copyright",
                text: $copyright,
                validation: copyright.nilIfEmpty == nil
                    ? L10n.text("Copyright owner is required.")
                    : nil
            )
        }
    }

    private var screenshotsSection: some View {
        Section("Screenshots") {
            configurationTextEditor(
                "Paths (one file or folder per line)",
                text: $screenshotPaths,
                height: 80
            )
            Toggle("Replace existing screenshots for matching device sizes", isOn: $replaceScreenshots)
            Text("Relative paths are resolved from the app project. The Publish overview automatically extracts and previews missing screenshots on every supported Simulator family.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var categoriesAndContentSection: some View {
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
    }

    private var pricingAndAvailabilitySection: some View {
        Section("Pricing and Availability") {
            Toggle("Configure app price and availability", isOn: $configureCommercialSettings)
            Toggle("The app itself is free", isOn: $appIsFree)
                .disabled(!configureCommercialSettings)
            AppStoreTerritoryPicker(
                title: "Base territory",
                selection: $appBaseTerritory,
                territoryIDs: currentConfiguration?.territoryIDs ?? []
            )
                .disabled(!configureCommercialSettings)
            Toggle("Available in all territories", isOn: $appAvailableEverywhere)
                .disabled(!configureCommercialSettings)
        }
    }

    private var licenseAgreementSection: some View {
        Section("Custom End-User License Agreement") {
            configurationTextEditor("Agreement text", text: $licenseAgreementText, height: 180)
            Text("Apple’s API accepts agreement text, not a terms URL. The Terms of Use URL from Store Listing is also appended to the App Store description.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ageRatingsSection: some View {
        Section("Age Ratings") {
            Button {
                Task { await generateAIAgeRatingDraft() }
            } label: {
                if isGeneratingAgeRating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing project source for Age Ratings…")
                    }
                } else {
                    Label("Fill Age Ratings with OpenAI", systemImage: "sparkles")
                }
            }
            .disabled(isGeneratingAI || isGeneratingAgeRating || isGeneratingPrivacy)
            PublishingAgeRatingFields(ageRating: $ageRating)
            Text("OpenAI scans the source repository and defaults unsupported age-rating answers to No or None. Positive answers require repository evidence; review every field before publishing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appPrivacySection: some View {
        Section("App Privacy Draft") {
            Button {
                Task { await generateAIPrivacyDraft() }
            } label: {
                if isGeneratingPrivacy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing project source for App Privacy…")
                    }
                } else {
                    Label("Fill App Privacy with OpenAI", systemImage: "sparkles")
                }
            }
            .disabled(isGeneratingAI || isGeneratingAgeRating || isGeneratingPrivacy)
            PublishingPrivacyDraftFields(
                isSpecified: Binding(
                    get: { privacyDraftIsSpecified },
                    set: { value in
                        privacyDraftIsSpecified = value
                        privacyConfirmedInAppStoreConnect = false
                        privacyConfirmedManually = false
                    }
                ),
                collectsData: Binding(
                    get: { privacyCollectsData },
                    set: { value in
                        privacyCollectsData = value
                        if value {
                            privacyConfirmedInAppStoreConnect = false
                        } else {
                            privacyConfirmedManually = false
                        }
                    }
                ),
                dataTypes: $privacyDataTypes,
                notes: $privacyNotes
            )
            Text("Apple does not expose App Privacy through its public API. After you review and authorize a no-data declaration, Development Management publishes it through the Fastlane session stored in Publishing Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if privacyDraftIsSpecified {
                if privacyCollectsData {
                    Toggle(
                        "I published these App Privacy answers in App Store Connect",
                        isOn: $privacyConfirmedManually
                    )
                } else {
                    Toggle(
                        "I reviewed and authorize automatic App Privacy publishing",
                        isOn: $privacyConfirmedInAppStoreConnect
                    )
                }
                TextField("Authorized by", text: $privacyConfirmedBy)
                    .disabled(!privacyConfirmedInAppStoreConnect && !privacyConfirmedManually)
            } else {
                Text("Unspecified means the repository does not establish the App Privacy answer; it is never treated as No.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsRequiredFieldErrors, let privacyEditorValidationMessage {
                Label(privacyEditorValidationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if privacyDraftIsSpecified,
               privacyConfirmedInAppStoreConnect || privacyConfirmedManually,
               !privacyConfirmedAt.isEmpty {
                LabeledContent("Authorized at") {
                    Text(verbatim: privacyConfirmedAt)
                        .textSelection(.enabled)
                }
            }
            if privacyDraftIsSpecified, privacyCollectsData {
                Label(
                    "Automatic publishing currently supports only the “Data Not Collected” answer. Complete collected-data details in App Store Connect.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .id(PublishingConfigurationEditorAnchor.appPrivacy)
    }

    private var appReviewContactSection: some View {
        Section("App Review Contact") {
            requiredTextField(
                "First name",
                text: $reviewFirstName,
                validation: requiredReviewMessage(for: reviewFirstName)
            )
            requiredTextField(
                "Last name",
                text: $reviewLastName,
                validation: requiredReviewMessage(for: reviewLastName)
            )
            requiredTextField(
                "Phone",
                text: $reviewPhone,
                validation: requiredReviewMessage(for: reviewPhone)
            )
            requiredTextField(
                "Email",
                text: $reviewEmail,
                validation: requiredReviewMessage(for: reviewEmail)
            )
            configurationTextEditor("Review notes", text: $reviewNotes, height: 100)
            Toggle("A demo account is required", isOn: $demoAccountRequired)
            Text("Demo credentials are managed in Publishing Settings and stored only in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var submissionSection: some View {
        Section("Submission") {
            Toggle("Release automatically after Apple approves it", isOn: $releaseAutomatically)
            Text("Both release actions synchronize this configuration. Publish submits the app and subscriptions for App Review; Upload to TestFlight stops immediately before submission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var testFlightSection: some View {
        Section("TestFlight") {
            TextField("Internal group name", text: $testFlightGroupName)
            TextField("Feedback email", text: $testFlightFeedbackEmail)
            configurationTextEditor("Beta review notes", text: $testFlightReviewNotes, height: 80)
            configurationTextEditor(
                "Internal tester emails (one per line)",
                text: $internalTesterEmails,
                height: 70
            )
            Text("Internal testers must already be members of the App Store Connect team. Both release actions synchronize beta descriptions, URLs, review details, the group, and these testers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewAttachmentsSection: some View {
        Section("Review Attachments") {
            configurationTextEditor(
                "Demo videos or documents (one file or folder per line)",
                text: $reviewAttachmentPaths,
                height: 80
            )
            Text("Relative paths are resolved from the app project. Publish also discovers files in AppStore/ReviewAttachments.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .frame(height: height)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func requiredTextField(
        _ title: String,
        text: Binding<String>,
        validation: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L10n.text(title), text: text)
                .textFieldStyle(.roundedBorder)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            showsRequiredFieldErrors && validation != nil ? Color.red : Color.clear,
                            lineWidth: 1.5
                        )
                }
            if showsRequiredFieldErrors, let validation {
                Label(validation, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var supportURLValidation: String? {
        guard let value = supportURL.nilIfEmpty else {
            return L10n.text("Support URL is required.")
        }
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return L10n.text("Enter a valid HTTP or HTTPS URL.")
        }
        return nil
    }

    private var privacyPolicyURLValidation: String? {
        requiredURLValidation(
            privacyPolicyURL,
            missingMessage: L10n.text("Privacy policy URL is required.")
        )
    }

    private var termsURLValidation: String? {
        requiredURLValidation(
            termsURL,
            missingMessage: L10n.text("Terms of Use URL is required for apps with subscriptions.")
        )
    }

    private func requiredURLValidation(_ value: String, missingMessage: String) -> String? {
        guard let value = value.nilIfEmpty else { return missingMessage }
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return L10n.text("Enter a valid HTTP or HTTPS URL.")
        }
        return nil
    }

    private var requiresTermsURL: Bool {
        (baseManifest?.subscriptions?.groups ?? []).contains { !$0.subscriptions.isEmpty }
    }

    private func requiredReviewMessage(for value: String) -> String? {
        value.nilIfEmpty == nil
            ? L10n.text("This field is required for App Review.")
            : nil
    }

    private var privacyEditorValidationMessage: String? {
        guard privacyDraftIsSpecified else {
            return L10n.text("Specify the App Privacy answer before saving. Unknown is not treated as No.")
        }
        if privacyCollectsData, privacyDataTypes.isEmpty {
            return L10n.text("Select at least one collected data type, or leave the App Privacy answer Unspecified.")
        }
        let isConfirmed = privacyCollectsData
            ? privacyConfirmedManually
            : privacyConfirmedInAppStoreConnect || privacyConfirmedManually
        guard isConfirmed else {
            return privacyCollectsData
                ? L10n.text("Confirm that the collected-data App Privacy details were published in App Store Connect.")
                : L10n.text("Review the App Privacy draft and authorize automatic publishing.")
        }
        guard privacyConfirmedBy.nilIfEmpty != nil else {
            return L10n.text("Enter who reviewed and authorized the App Privacy answers.")
        }
        return nil
    }

    private func revealAppPrivacySection() {
        selectedTab = .appSetup
        pendingScrollAnchor = .appPrivacy
        scrollRequestRevision &+= 1
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
                        familySharable: firstSubscription?.familySharable,
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
                familySharable: manifest.subscriptions?.familySharable
                    ?? currentConfiguration.subscriptionGroups
                        .flatMap(\.subscriptions)
                        .allSatisfy(\.familySharable),
                reviewScreenshot: manifest.subscriptions?.reviewScreenshot,
                groups: groups
            )
        }
    }

    private func loadFields(from manifest: AppStorePublishingManifest) {
        let publication = manifest.publication ?? defaultPublicationConfiguration()
        let configuredLocale = publication.locale ?? "en-US"
        locale = AppStoreLocale.canonicalIdentifier(configuredLocale) ?? configuredLocale
        appName = publication.appName ?? ""
        subtitle = publication.subtitle ?? publication.metadata?.subtitle ?? ""
        description = publication.metadata?.description ?? ""
        keywords = publication.metadata?.keywords ?? ""
        promotionalText = publication.metadata?.promotionalText ?? ""
        whatsNew = publication.metadata?.whatsNew ?? ""
        let normalizedLocalizations = AppStorePublishingService.normalizedLocalizedMetadata(
            publication.localizations ?? []
        )
        if !normalizedLocalizations.isEmpty {
            let localizations = normalizedLocalizations
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
        expandedAdditionalLocalizationIndex = PublishingLocalizationAccordionPolicy.initialExpandedIndex(
            itemCount: additionalLocalizations.count
        )
        copyright = AppStoreCopyrightNormalizer.normalized(publication.copyright ?? "")
        supportURL = publication.supportURL ?? ""
        marketingURL = publication.marketingURL ?? ""
        termsURL = publication.termsURL ?? ""
        privacyPolicyURL = publication.privacyPolicyURL ?? ""
        privacyChoicesURL = publication.privacyChoicesURL ?? ""
        screenshotPaths = (publication.screenshotPaths ?? []).joined(separator: "\n")
        reviewAttachmentPaths = (publication.reviewAttachmentPaths ?? []).joined(separator: "\n")
        replaceScreenshots = publication.replaceScreenshots ?? false
        releaseAutomatically = publication.releaseAutomatically ?? true
        reviewFirstName = publication.review?.contactFirstName ?? ""
        reviewLastName = publication.review?.contactLastName ?? ""
        reviewPhone = publication.review?.contactPhone ?? ""
        reviewEmail = publication.review?.contactEmail ?? ""
        reviewNotes = publication.review?.notes ?? ""
        demoAccountRequired = publication.review?.demoAccountRequired ?? false
        testFlightGroupName = publication.testFlight?.groupName ?? "Internal Testing"
        testFlightFeedbackEmail = publication.testFlight?.feedbackEmail
            ?? publication.review?.contactEmail
            ?? ""
        testFlightReviewNotes = publication.testFlight?.reviewNotes ?? publication.review?.notes ?? ""
        internalTesterEmails = (publication.testFlight?.internalTesterEmails ?? []).joined(separator: "\n")

        let application = manifest.application
        primaryCategory = application?.primaryCategory ?? publication.metadata?.primaryCategory ?? ""
        secondaryCategory = application?.secondaryCategory ?? publication.metadata?.secondaryCategory ?? ""
        contentRights = application?.contentRightsDeclaration ?? ""
        ageRating = application?.ageRating ?? [:]
        configureCommercialSettings = application?.isFree != nil || application?.availableInAllTerritories != nil
        appIsFree = application?.isFree ?? true
        appBaseTerritory = application?.baseTerritory ?? "USA"
        appAvailableEverywhere = application?.availableInAllTerritories ?? true
        licenseAgreementText = publication.licenseAgreementText ?? ""
        privacyDraftIsSpecified = manifest.compliance?.privacyDraft != nil
        privacyCollectsData = manifest.compliance?.privacyDraft?.collectsData ?? false
        privacyDataTypes = manifest.compliance?.privacyDraft?.dataTypes ?? []
        privacyNotes = manifest.compliance?.privacyDraft?.notes ?? []
        privacyConfirmedInAppStoreConnect = manifest.compliance?.privacyAttestation?
            .automaticPublishingAuthorizedAt?.nilIfEmpty != nil
        privacyConfirmedManually = manifest.compliance?.privacyAttestation != nil
            && manifest.compliance?.privacyAttestation?.automaticPublishingAuthorizedAt?.nilIfEmpty == nil
        privacyConfirmedBy = manifest.compliance?.privacyAttestation?.confirmedBy ?? ""
        privacyConfirmedAt = manifest.compliance?.privacyAttestation?.confirmedAt ?? ""
        complianceEvidence = manifest.compliance?.evidence ?? []
        complianceConfidence = manifest.compliance?.confidence

        subscriptionBaseTerritory = manifest.subscriptions?.baseTerritory ?? ""
        subscriptionsAvailableEverywhere = manifest.subscriptions?.availableInAllTerritories ?? true
        subscriptionsFamilySharable = manifest.subscriptions?.familySharable
            ?? (manifest.subscriptions?.groups ?? [])
                .flatMap(\.subscriptions)
                .allSatisfy { $0.familySharable == true }
        subscriptionReviewScreenshot = manifest.subscriptions?.reviewScreenshot ?? ""
        subscriptionGroups = (manifest.subscriptions?.groups ?? []).map(PublishingSubscriptionGroupForm.init)
    }

    private func makeManifest() throws -> AppStorePublishingManifest {
        try validateSubscriptionForm()
        var manifest = baseManifest ?? AppStorePublishingManifest(
            schemaVersion: 1,
            publication: nil,
            application: nil,
            subscriptions: nil
        )
        let metadata = AppStoreMetadata(
            description: description,
            keywords: keywords,
            promotionalText: promotionalText,
            whatsNew: whatsNew,
            subtitle: subtitle.nilIfEmpty,
            primaryCategory: primaryCategory.nilIfEmpty,
            secondaryCategory: secondaryCategory.nilIfEmpty
        )
        let normalizedLocale = AppStoreLocale.canonicalIdentifier(locale) ?? locale
        let normalizedAdditionalLocalizations = additionalLocalizations.map { localization in
            var normalized = localization
            normalized.locale = AppStoreLocale.canonicalIdentifier(localization.locale)
                ?? localization.locale
            return normalized
        }
        let localizations: [AppStoreLocalizedMetadata]? = [
            AppStoreLocalizedMetadata(
                locale: normalizedLocale,
                appName: appName,
                subtitle: subtitle,
                description: description,
                keywords: keywords,
                promotionalText: promotionalText,
                whatsNew: whatsNew
            )
        ] + normalizedAdditionalLocalizations
        manifest.publication = AppStorePublicationConfiguration(
            locale: normalizedLocale.nilIfEmpty,
            copyright: copyright.nilIfEmpty.map { AppStoreCopyrightNormalizer.normalized($0) },
            supportURL: supportURL.nilIfEmpty,
            marketingURL: marketingURL.nilIfEmpty,
            termsURL: termsURL.nilIfEmpty,
            privacyPolicyURL: privacyPolicyURL.nilIfEmpty,
            privacyChoicesURL: privacyChoicesURL.nilIfEmpty,
            appName: appName.nilIfEmpty,
            subtitle: subtitle.nilIfEmpty,
            licenseAgreementText: licenseAgreementText.nilIfEmpty,
            releaseAutomatically: releaseAutomatically,
            metadata: metadata,
            localizations: localizations,
            screenshotPaths: screenshotPaths.split(whereSeparator: \.isNewline).map(String.init),
            reviewAttachmentPaths: reviewAttachmentPaths.split(whereSeparator: \.isNewline).map(String.init),
            replaceScreenshots: replaceScreenshots,
            review: AppStoreReviewManifestConfiguration(
                contactFirstName: reviewFirstName.nilIfEmpty,
                contactLastName: reviewLastName.nilIfEmpty,
                contactPhone: reviewPhone.nilIfEmpty,
                contactEmail: reviewEmail.nilIfEmpty,
                notes: reviewNotes.nilIfEmpty,
                demoAccountRequired: demoAccountRequired
            ),
            testFlight: AppStoreTestFlightConfiguration(
                groupName: testFlightGroupName.nilIfEmpty,
                feedbackEmail: testFlightFeedbackEmail.nilIfEmpty,
                reviewNotes: testFlightReviewNotes.nilIfEmpty,
                internalTesterEmails: internalTesterEmails
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { $0.nilIfEmpty != nil }
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
        application.ageRating = ageRating.isEmpty ? nil : ageRating
        manifest.application = application
        if privacyDraftIsSpecified {
            let previousDraft = manifest.compliance?.privacyDraft
            let currentDraft = AppStorePrivacyDraft(
                collectsData: privacyCollectsData,
                dataTypes: privacyDataTypes,
                notes: privacyNotes
            )
            let previousAttestation = manifest.compliance?.privacyAttestation
            let now = ISO8601DateFormatter().string(from: Date())
            let privacyAttestation: AppStorePrivacyAttestation? = if privacyConfirmedInAppStoreConnect {
                AppStorePrivacyAttestation(
                    confirmedBy: privacyConfirmedBy.nilIfEmpty,
                    confirmedAt: previousDraft == currentDraft
                        ? previousAttestation?.confirmedAt?.nilIfEmpty
                            ?? privacyConfirmedAt.nilIfEmpty
                            ?? now
                        : now,
                    projectFingerprint: previousAttestation?.projectFingerprint,
                    automaticPublishingAuthorizedAt: previousDraft == currentDraft
                        ? previousAttestation?.automaticPublishingAuthorizedAt?.nilIfEmpty ?? now
                        : now,
                    publishedAt: previousDraft == currentDraft
                        ? previousAttestation?.publishedAt
                        : nil
                )
            } else if privacyConfirmedManually {
                AppStorePrivacyAttestation(
                    confirmedBy: privacyConfirmedBy.nilIfEmpty,
                    confirmedAt: previousDraft == currentDraft
                        ? previousAttestation?.confirmedAt?.nilIfEmpty
                            ?? privacyConfirmedAt.nilIfEmpty
                            ?? now
                        : now,
                    projectFingerprint: previousAttestation?.projectFingerprint
                )
            } else {
                nil
            }
            manifest.compliance = AppStoreComplianceConfiguration(
                privacyDraft: currentDraft,
                privacyAttestation: privacyAttestation,
                evidence: complianceEvidence,
                confidence: complianceConfidence
            )
        } else {
            manifest.compliance = nil
        }

        manifest.subscriptions = AppStoreSubscriptionsConfiguration(
            baseTerritory: subscriptionBaseTerritory.nilIfEmpty,
            availableInAllTerritories: subscriptionsAvailableEverywhere,
            familySharable: subscriptionsFamilySharable,
            reviewScreenshot: subscriptionReviewScreenshot.nilIfEmpty,
            groups: subscriptionGroups.isEmpty ? nil : subscriptionGroups.map(\.definition)
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
        aiGenerationNotice = nil
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
            if locale.isEmpty { locale = primary.locale }
            if appName.isEmpty { appName = primary.appName }
            if subtitle.isEmpty { subtitle = primary.subtitle }
            if description.isEmpty { description = primary.description }
            if keywords.isEmpty { keywords = primary.keywords }
            if promotionalText.isEmpty { promotionalText = primary.promotionalText }
            if whatsNew.isEmpty { whatsNew = primary.whatsNew }
            let savedLocales = Set(additionalLocalizations.map { $0.locale.lowercased() })
            additionalLocalizations.append(contentsOf: generated.localizations.enumerated().compactMap { index, localization in
                guard index != primaryIndex,
                      !savedLocales.contains(localization.locale.lowercased()) else { return nil }
                return localization
            })
            if expandedAdditionalLocalizationIndex == nil {
                expandedAdditionalLocalizationIndex = PublishingLocalizationAccordionPolicy.initialExpandedIndex(
                    itemCount: additionalLocalizations.count
                )
            }
            detectedLocales = generated.localizations.map(\.locale)
            if primaryCategory.isEmpty { primaryCategory = generated.primaryCategory }
            if secondaryCategory.isEmpty { secondaryCategory = generated.secondaryCategory }
            let compliance = generated.compliance
            if contentRights.isEmpty {
                contentRights = compliance.contentRightsDeclaration
            }
            if copyright.isEmpty, !compliance.copyright.isEmpty {
                copyright = AppStoreCopyrightNormalizer.normalized(compliance.copyright)
            }
            if baseManifest?.application?.isFree == nil {
                configureCommercialSettings = true
                appIsFree = compliance.appIsFree
            }
            if baseManifest?.publication?.review?.demoAccountRequired == nil {
                demoAccountRequired = compliance.demoAccountRequired
            }
            ageRating = compliance.ageRatingDefaultingUnknownToNo
            applyGeneratedPrivacyDraft(from: compliance)
            complianceEvidence = compliance.evidence
            complianceConfidence = compliance.confidence
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func generateAIAgeRatingDraft() async {
        isGeneratingAgeRating = true
        defer { isGeneratingAgeRating = false }
        aiGenerationNotice = nil
        do {
            let compliance = try await model.generateAppStoreComplianceDraft(projectID: project.id)
            ageRating = compliance.ageRatingDefaultingUnknownToNo
            complianceEvidence = compliance.evidence
            complianceConfidence = compliance.confidence
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func generateAIPrivacyDraft() async {
        isGeneratingPrivacy = true
        defer { isGeneratingPrivacy = false }
        aiGenerationNotice = nil
        do {
            let compliance = try await model.generateAppStoreComplianceDraft(projectID: project.id)
            applyGeneratedPrivacyDraft(from: compliance)
            complianceEvidence = compliance.evidence
            complianceConfidence = compliance.confidence
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func applyGeneratedPrivacyDraft(from compliance: AppStoreComplianceDraft) {
        guard let generatedPrivacy = compliance.evidenceBackedPrivacy else {
            privacyDraftIsSpecified = false
            privacyCollectsData = false
            privacyDataTypes = []
            privacyNotes = []
            privacyConfirmedInAppStoreConnect = false
            privacyConfirmedManually = false
            privacyConfirmedBy = ""
            privacyConfirmedAt = ""
            aiGenerationNotice = L10n.text(
                "OpenAI could not establish the complete App Privacy answer from the source repository. The answer is now Unspecified for manual review."
            )
            return
        }
        privacyDraftIsSpecified = true
        privacyCollectsData = generatedPrivacy.collectsData
        privacyDataTypes = generatedPrivacy.dataTypes
        privacyNotes = generatedPrivacy.notes
        privacyConfirmedInAppStoreConnect = false
        privacyConfirmedManually = false
        privacyConfirmedAt = ""
    }

    private func save() {
        showsRequiredFieldErrors = true
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
        } else {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(L10n.text("Support URL is required."))
        }
        guard let privacyPolicyURL = manifest.publication?.privacyPolicyURL?.nilIfEmpty else {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(L10n.text("Privacy policy URL is required."))
        }
        guard let privacyURL = URL(string: privacyPolicyURL),
              ["http", "https"].contains(privacyURL.scheme?.lowercased() ?? ""),
              privacyURL.host != nil else {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(
                L10n.text("publication.privacyPolicyURL must be a valid HTTP or HTTPS URL.")
            )
        }
        let hasSubscriptions = (manifest.subscriptions?.groups ?? []).contains {
            !$0.subscriptions.isEmpty
        }
        if hasSubscriptions, manifest.publication?.termsURL?.nilIfEmpty == nil {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(
                L10n.text("Terms of Use URL is required for apps with subscriptions.")
            )
        }
        guard manifest.publication?.copyright?.nilIfEmpty != nil else {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(L10n.text("Copyright owner is required."))
        }
        if let privacyDraft = manifest.compliance?.privacyDraft,
           privacyDraft.collectsData,
           privacyDraft.dataTypes.isEmpty {
            revealAppPrivacySection()
            throw ConfigurationEditorError.invalid(
                L10n.text("Select at least one collected data type, or leave the App Privacy answer Unspecified.")
            )
        }
        switch AppStorePrivacyConfigurationPolicy.state(for: manifest.compliance) {
        case .missingDraft:
            revealAppPrivacySection()
            throw ConfigurationEditorError.invalid(
                L10n.text("Review the App Privacy draft before saving the publishing configuration.")
            )
        case .needsAutomaticAuthorization:
            revealAppPrivacySection()
            throw ConfigurationEditorError.invalid(
                L10n.text("Review the App Privacy draft, authorize automatic publishing, and enter who authorized it.")
            )
        case .needsManualConfirmation:
            revealAppPrivacySection()
            throw ConfigurationEditorError.invalid(
                L10n.text("Confirm that the collected-data App Privacy details were published in App Store Connect and enter who confirmed them.")
            )
        case .automaticallyAuthorized, .confirmed:
            break
        }
        let review = manifest.publication?.review
        let contact = [
            review?.contactFirstName?.nilIfEmpty,
            review?.contactLastName?.nilIfEmpty,
            review?.contactPhone?.nilIfEmpty,
            review?.contactEmail?.nilIfEmpty
        ]
        guard contact.allSatisfy({ $0 != nil }) else {
            selectedTab = .review
            throw ConfigurationEditorError.invalid(
                L10n.text("Complete every highlighted App Review contact field.")
            )
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
        guard manifest.publication?.metadata != nil
                || manifest.publication?.localizations?.isEmpty == false else {
            selectedTab = .listing
            throw ConfigurationEditorError.invalid(
                L10n.text("Generate or enter the App Store listing, review it, and save it before releasing.")
            )
        }
        var locales: Set<String> = []
        for localization in manifest.publication?.localizations ?? [] {
            guard let normalizedLocale = AppStoreLocale.canonicalIdentifier(localization.locale),
                  locales.insert(normalizedLocale.lowercased()).inserted else {
                throw ConfigurationEditorError.invalid(
                    L10n.text("Localized listings require supported, unique App Store locale identifiers such as en-US or he.")
                )
            }
            guard localization.description.nilIfEmpty != nil else {
                throw ConfigurationEditorError.invalid(
                    L10n.format("The %@ listing requires a non-empty description.", localization.locale)
                )
            }
        }
        guard let application = manifest.application,
              application.primaryCategory?.nilIfEmpty != nil,
              application.contentRightsDeclaration?.nilIfEmpty != nil,
              application.isFree != nil,
              AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(application.ageRating ?? [:]) else {
            selectedTab = .appSetup
            throw ConfigurationEditorError.invalid(
                L10n.text("Complete the editable category, content-rights, free-download, and age-rating answers before releasing.")
            )
        }
        var productIDs: Set<String> = []
        let existingProductIDs = Set(
            currentConfiguration?.subscriptionGroups.flatMap(\.subscriptions).map(\.productID) ?? []
        )
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
                if !existingProductIDs.contains(subscription.productID),
                   subscription.basePrice?.nilIfEmpty == nil {
                    selectedTab = .subscriptions
                    throw ConfigurationEditorError.invalid(
                        L10n.format("New subscription %@ requires a base price.", subscription.productID)
                    )
                }
            }
        }
    }

    private func validateSubscriptionForm() throws {
        for group in subscriptionGroups {
            for product in group.subscriptions {
                guard let level = Int(product.groupLevel), level > 0 else {
                    selectedTab = .subscriptions
                    throw ConfigurationEditorError.invalid(
                        L10n.format("Subscription %@ requires a positive numeric group level.", product.productID)
                    )
                }
                var territories = Set<String>()
                for entry in product.territoryPrices {
                    guard let territory = entry.territory.nilIfEmpty,
                          let price = entry.price.nilIfEmpty else {
                        selectedTab = .subscriptions
                        throw ConfigurationEditorError.invalid(
                            L10n.format("Complete every territory and price for %@.", product.productID)
                        )
                    }
                    guard territories.insert(territory.uppercased()).inserted else {
                        selectedTab = .subscriptions
                        throw ConfigurationEditorError.invalid(
                            L10n.format("Territory prices for %@ contain duplicate territory %@.", product.productID, territory)
                        )
                    }
                    guard Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")) != nil else {
                        selectedTab = .subscriptions
                        throw ConfigurationEditorError.invalid(
                            L10n.format("%@ is not a valid price for territory %@.", price, territory)
                        )
                    }
                }
            }
        }
    }

    private func defaultPublicationConfiguration() -> AppStorePublicationConfiguration {
        AppStorePublicationConfiguration(
            locale: defaults.appStoreLocale?.nilIfEmpty ?? "en-US",
            copyright: defaults.appStoreCopyright,
            supportURL: defaults.appStoreSupportURL,
            releaseAutomatically: defaults.appStoreReleaseAutomatically ?? true,
            metadata: nil,
            screenshotPaths: ["Screenshots"],
            reviewAttachmentPaths: ["AppStore/ReviewAttachments"],
            review: AppStoreReviewManifestConfiguration(
                contactFirstName: defaults.appStoreReviewFirstName,
                contactLastName: defaults.appStoreReviewLastName,
                contactPhone: defaults.appStoreReviewPhone,
                contactEmail: defaults.appStoreReviewEmail,
                notes: defaults.appStoreReviewNotes,
                demoAccountRequired: defaults.appStoreReviewDemoAccountRequired ?? false
            ),
            testFlight: AppStoreTestFlightConfiguration(
                groupName: "Internal Testing",
                feedbackEmail: defaults.appStoreReviewEmail,
                reviewNotes: defaults.appStoreReviewNotes,
                internalTesterEmails: defaults.appStoreReviewEmail.map { [$0] }
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

    private func friendlyCategory(_ identifier: String) -> String {
        identifier.split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
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
