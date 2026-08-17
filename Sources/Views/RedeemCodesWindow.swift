import AppKit
import SwiftUI

@MainActor
final class RedeemCodesWindowPresenter {
    static let shared = RedeemCodesWindowPresenter()

    private var windowController: NSWindowController?

    private init() {}

    func show(model: AppModel, projectID: UUID) {
        windowController?.close()
        let projectName = model.projects.first(where: { $0.id == projectID })?.displayName
            ?? L10n.text("Application")
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.format("Redeem Codes — %@", projectName)
        panel.contentViewController = NSHostingController(
            rootView: RedeemCodesWindowView(projectID: projectID)
                .environmentObject(model)
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
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

private struct RedeemCodesWindowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    let projectID: UUID

    @State private var snapshot: AppStoreConnectConfigurationSnapshot?
    @State private var isLoading = true
    @State private var loadError: String?
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
    @State private var status: RedeemCodeStatus?
    @State private var generatedCodes: [String] = []
    @State private var generatedCodesWereCopied = false
    @State private var oneTimeCodeSaveURL: URL?
    @State private var showsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 580)
        .task(id: projectID) {
            await refresh()
        }
        .onChange(of: selectedProductID) { _, _ in
            clearGeneratedCodes()
        }
        .onChange(of: codeKind) { _, _ in
            clearGeneratedCodes()
            if !SubscriptionOfferCodeBatchSize.isValid(numberOfCodes) {
                numberOfCodes = 500
            }
        }
        .confirmationDialog(
            Text("Generate production offer codes?"),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(codeKind == .oneTime ? "Generate one-time codes" : "Create custom code") {
                Task { await generateCodes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates an immutable free subscription offer and a production code batch in App Store Connect. The app and subscription must already be approved for production codes.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ticket.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Redeem Codes")
                    .font(.title2.bold())
                Text(projectName)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isLoading {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isGeneratingOfferCodes)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Checking whether this app can create production redeem codes…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("App Store Connect needs attention", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(verbatim: loadError)
            } actions: {
                Button("Try Again") {
                    Task { await refresh() }
                }
                Button("Publishing Settings…") {
                    openSettings()
                }
            }
        } else if generatedCodes.isEmpty {
            redeemCodeForm
        } else {
            generatedCodeResult
        }
    }

    private var redeemCodeForm: some View {
        Form {
            Section("Subscription") {
                if subscriptions.isEmpty {
                    Label("No subscriptions exist in App Store Connect.", systemImage: "creditcard.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Product", selection: $selectedProductID) {
                        ForEach(subscriptions) { subscription in
                            Text(subscription.referenceName).tag(subscription.productID)
                        }
                    }
                    if let subscription = selectedSubscription {
                        LabeledContent("Product ID") {
                            Text(verbatim: subscription.productID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("Production codes require an app that is ready for distribution and an approved subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let eligibilityIssue {
                Section("Availability") {
                    Label("Redeem codes are not available yet", systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(verbatim: eligibilityIssue)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                existingCodesSection
                offerSection
                codesSection
            }
        }
        .formStyle(.grouped)
    }

    private var existingCodesSection: some View {
        Section("Existing Redeem Codes") {
            if let subscription = selectedSubscription {
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
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var offerSection: some View {
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
    }

    private var codesSection: some View {
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
            if let status {
                statusView(status)
            }
            HStack {
                Spacer()
                Button {
                    handleGenerateAction()
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

    private var generatedCodeResult: some View {
        Form {
            Section(generatedCodes.count == 1 ? "Your Redeem Code" : "Your Redeem Codes") {
                ScrollView {
                    Text(verbatim: generatedCodes.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 360)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    copyGeneratedCodes()
                } label: {
                    Label(
                        generatedCodesWereCopied
                            ? L10n.text("Copied")
                            : L10n.text(generatedCodes.count == 1 ? "Copy Code" : "Copy All Codes"),
                        systemImage: generatedCodesWereCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
                Button("Create Another Code") {
                    clearGeneratedCodes()
                    Task { await refresh(preservingForm: true) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Button("Publishing Settings…") {
                openSettings()
            }
            Spacer()
            Button("Close") {
                RedeemCodesWindowPresenter.shared.close()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var projectName: String {
        model.projects.first(where: { $0.id == projectID })?.displayName
            ?? L10n.text("Application")
    }

    private var subscriptions: [AppStoreConnectSubscriptionSnapshot] {
        snapshot?.subscriptionGroups
            .flatMap(\.subscriptions)
            .sorted {
                $0.referenceName.localizedCaseInsensitiveCompare($1.referenceName) == .orderedAscending
            } ?? []
    }

    private var selectedSubscription: AppStoreConnectSubscriptionSnapshot? {
        subscriptions.first(where: { $0.productID == selectedProductID })
    }

    private var eligibilityIssue: String? {
        guard let snapshot else { return L10n.text("Choose an available App Store subscription.") }
        guard snapshot.hasReadyForDistributionVersion else {
            return L10n.text("Redeem codes become available after Apple approves and releases the app.")
        }
        guard let subscription = selectedSubscription else {
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

    private var validationIssue: String? {
        if let eligibilityIssue { return eligibilityIssue }
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

    private func refresh(preservingForm: Bool = false) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let updated = try await model.loadAppStoreConnectConfiguration(projectID: projectID)
            snapshot = updated
            let availableProductIDs = Set(updated.subscriptionGroups
                .flatMap(\.subscriptions)
                .map(\.productID))
            if !availableProductIDs.contains(selectedProductID) {
                selectedProductID = availableProductIDs.sorted().first ?? ""
            }
            if !preservingForm {
                clearGeneratedCodes()
            }
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            loadError = error.localizedDescription
        }
    }

    private func handleGenerateAction() {
        if let validationIssue {
            status = .failure(validationIssue)
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
        showsConfirmation = true
    }

    private func generateCodes() async {
        status = nil
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
                    status = .failure(L10n.format(
                        "Batch %@ was created, but the CSV could not be saved: %@",
                        result.batchID,
                        error.localizedDescription
                    ))
                    return
                }
                status = .success(L10n.format(
                    "Generated %d codes and saved %@.",
                    numberOfCodes,
                    oneTimeCodeSaveURL.lastPathComponent
                ))
            } else if codeKind == .oneTime {
                status = .warning(L10n.format(
                    "The batch was created, but Apple is still preparing its CSV. Batch ID: %@",
                    result.batchID
                ))
            } else {
                generatedCodes = [result.customCode ?? customCode]
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func copyGeneratedCodes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedCodes.joined(separator: "\n"), forType: .string)
        generatedCodesWereCopied = true
    }

    private func clearGeneratedCodes() {
        generatedCodes = []
        generatedCodesWereCopied = false
        oneTimeCodeSaveURL = nil
        status = nil
    }

    private func friendlyState(_ rawValue: String) -> String {
        rawValue
            .split(separator: "_")
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }

    @ViewBuilder
    private func statusView(_ status: RedeemCodeStatus) -> some View {
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

private enum RedeemCodeStatus: Equatable {
    case success(String)
    case warning(String)
    case failure(String)
}
