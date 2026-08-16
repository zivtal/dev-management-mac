import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PublishingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var openAIAPIKey = ""
    @State private var demoAccountName = ""
    @State private var demoAccountPassword = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("OpenAI API key", text: $openAIAPIKey)
                    .textContentType(.password)
                HStack {
                    credentialStatus(
                        isStored: model.hasOpenAIAPIKey,
                        storedText: "API key stored in Keychain"
                    )
                    Spacer()
                    if model.hasOpenAIAPIKey {
                        Button("Remove", role: .destructive) {
                            model.removeOpenAIAPIKey()
                        }
                    }
                    Button(model.hasOpenAIAPIKey ? "Replace API Key" : "Save API Key") {
                        model.saveOpenAIAPIKey(openAIAPIKey)
                        openAIAPIKey = ""
                    }
                    .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                LabeledContent("Model") {
                    TextField("gpt-5.6-luna", text: optionalTextBinding(\.openAIModel, fallback: "gpt-5.6-luna"))
                        .labelsHidden()
                        .frame(width: 220)
                }
                Text("Save the key here, then use Generate Settings with OpenAI in the Publish window. OpenAI detects the app’s languages and creates a separate editable description, subtitle, keywords, promotional text, and release notes for each language, plus app categories. Publish also generates them automatically when no manual draft is saved. URLs, legal terms, prices, and review facts are never invented.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The app sends the application name, version, identifiers, and excerpts from its README or supported project manifest to the OpenAI Responses API. Swift and Objective-C source code and credentials are not uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default App Store Connect API") {
                LabeledContent("Issuer ID") {
                    TextField("Issuer ID", text: optionalTextBinding(\.appStoreConnectIssuerID))
                        .labelsHidden()
                        .frame(width: 340)
                }
                LabeledContent("Key ID") {
                    TextField("Key ID", text: optionalTextBinding(\.appStoreConnectKeyID))
                        .labelsHidden()
                        .frame(width: 220)
                }
                HStack {
                    credentialStatus(
                        isStored: model.hasAppStoreConnectPrivateKey,
                        storedText: ".p8 private key stored in Keychain"
                    )
                    Spacer()
                    if model.hasAppStoreConnectPrivateKey {
                        Button("Remove", role: .destructive) {
                            model.removeAppStoreConnectPrivateKey()
                        }
                    }
                    Button(model.hasAppStoreConnectPrivateKey ? "Replace Private Key…" : "Import Private Key…") {
                        importPrivateKey(profileID: nil)
                    }
                }
                Text("Apps use this API unless a different profile is selected in the Publish window. The private key is stored only in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Additional App Store Connect APIs") {
                if credentialProfiles.isEmpty {
                    Text("Add another API profile when an app belongs to a different App Store Connect team or should use different credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(credentialProfiles) { profile in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Profile name") {
                                TextField(
                                    "Profile name",
                                    text: profileTextBinding(profile.id, keyPath: \.name)
                                )
                                .labelsHidden()
                                .frame(width: 260)
                            }
                            LabeledContent("Issuer ID") {
                                TextField(
                                    "Issuer ID",
                                    text: profileTextBinding(profile.id, keyPath: \.issuerID)
                                )
                                .labelsHidden()
                                .frame(width: 340)
                            }
                            LabeledContent("Key ID") {
                                TextField(
                                    "Key ID",
                                    text: profileTextBinding(profile.id, keyPath: \.keyID)
                                )
                                .labelsHidden()
                                .frame(width: 220)
                            }
                            HStack {
                                credentialStatus(
                                    isStored: model.hasAppStoreConnectPrivateKey(profileID: profile.id),
                                    storedText: ".p8 private key stored in Keychain"
                                )
                                Spacer()
                                if model.hasAppStoreConnectPrivateKey(profileID: profile.id) {
                                    Button("Remove Key", role: .destructive) {
                                        model.removeAppStoreConnectPrivateKey(profileID: profile.id)
                                    }
                                }
                                Button(
                                    model.hasAppStoreConnectPrivateKey(profileID: profile.id)
                                        ? "Replace Private Key…"
                                        : "Import Private Key…"
                                ) {
                                    importPrivateKey(profileID: profile.id)
                                }
                                Button("Remove Profile", role: .destructive) {
                                    model.removeAppStoreConnectCredentialProfile(profile.id)
                                }
                            }
                        }
                    } label: {
                        Label(
                            profile.name.nilIfEmpty ?? L10n.text("Unnamed API"),
                            systemImage: "key.horizontal"
                        )
                    }
                }
                Button {
                    model.addAppStoreConnectCredentialProfile()
                } label: {
                    Label("Add App Store Connect API", systemImage: "plus")
                }
            }

            Section("Publication") {
                LabeledContent("Store locale") {
                    TextField("en-US", text: optionalTextBinding(\.appStoreLocale, fallback: "en-US"))
                        .labelsHidden()
                        .frame(width: 120)
                }
                LabeledContent("Copyright owner") {
                    TextField("2026 Company Name", text: optionalTextBinding(\.appStoreCopyright))
                        .labelsHidden()
                        .frame(width: 340)
                }
                LabeledContent("Support URL") {
                    TextField("https://example.com/support", text: optionalTextBinding(\.appStoreSupportURL))
                        .labelsHidden()
                        .frame(width: 340)
                }
                Toggle(
                    "Release automatically after Apple approves it",
                    isOn: optionalBoolBinding(\.appStoreReleaseAutomatically, fallback: true)
                )
                Text("A project Screenshots folder is used first. Missing screenshots are captured automatically on the newest available Simulator for every supported family, including iPhone, iPad, Apple Watch, Apple TV, and Apple Vision Pro. Existing App Store Connect screenshot sets are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("On a first publication, local StoreKit configuration files and app-store-publishing.json are used to create and configure subscription groups, products, localizations, availability, pricing, review screenshots, categories, and age ratings. Later app versions reuse that setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use Edit Full Publishing Configuration in the Publish window to load current App Store Connect values, generate an editable AI draft, and override metadata, URLs, screenshots, review details, app setup, and subscriptions for the selected app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App Review") {
                LabeledContent("First name") {
                    TextField("First name", text: optionalTextBinding(\.appStoreReviewFirstName))
                        .labelsHidden()
                        .frame(width: 220)
                }
                LabeledContent("Last name") {
                    TextField("Last name", text: optionalTextBinding(\.appStoreReviewLastName))
                        .labelsHidden()
                        .frame(width: 220)
                }
                LabeledContent("Phone") {
                    TextField("Phone", text: optionalTextBinding(\.appStoreReviewPhone))
                        .labelsHidden()
                        .frame(width: 220)
                }
                LabeledContent("Email") {
                    TextField("Email", text: optionalTextBinding(\.appStoreReviewEmail))
                        .labelsHidden()
                        .frame(width: 300)
                }
                LabeledContent("Review notes") {
                    TextField("Optional instructions for Apple", text: optionalTextBinding(\.appStoreReviewNotes), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...5)
                        .frame(width: 380)
                }
                Toggle(
                    "A demo account is required to review the app",
                    isOn: optionalBoolBinding(\.appStoreReviewDemoAccountRequired, fallback: false)
                )
                if model.preferences.appStoreReviewDemoAccountRequired ?? false {
                    TextField("Demo account username", text: $demoAccountName)
                        .textContentType(.username)
                    SecureField("Demo account password", text: $demoAccountPassword)
                        .textContentType(.password)
                    HStack {
                        credentialStatus(
                            isStored: model.hasAppReviewDemoAccount,
                            storedText: "Demo account stored in Keychain"
                        )
                        Spacer()
                        if model.hasAppReviewDemoAccount {
                            Button("Remove", role: .destructive) {
                                model.removeAppReviewDemoAccount()
                            }
                        }
                        Button(model.hasAppReviewDemoAccount ? "Replace Demo Account" : "Save Demo Account") {
                            model.saveAppReviewDemoAccount(
                                name: demoAccountName,
                                password: demoAccountPassword
                            )
                            demoAccountName = ""
                            demoAccountPassword = ""
                        }
                        .disabled(
                            demoAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || demoAccountPassword.isEmpty
                        )
                    }
                    Text("Demo credentials are stored only in macOS Keychain and sent directly to App Store Connect for App Review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let log = model.publishingLog {
                Section("Latest publication") {
                    HStack {
                        if log.state == .inProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: statusSymbol(for: log.state))
                                .foregroundStyle(statusColor(for: log.state))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.state == .inProgress ? log.phase.title : statusTitle(for: log.state))
                                .fontWeight(.medium)
                            Text(log.projectName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if log.state == .inProgress {
                            Button("Cancel Publication", role: .destructive) {
                                model.cancelPublishing()
                            }
                        }
                    }

                    ScrollView {
                        Text(log.output.isEmpty ? L10n.text("Waiting for command output…") : log.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func credentialStatus(isStored: Bool, storedText: LocalizedStringKey) -> some View {
        Label(
            isStored ? storedText : LocalizedStringKey("Not configured"),
            systemImage: isStored ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundStyle(isStored ? .green : .secondary)
    }

    private func optionalTextBinding(
        _ keyPath: WritableKeyPath<AppPreferences, String?>,
        fallback: String = ""
    ) -> Binding<String> {
        Binding(
            get: { model.preferences[keyPath: keyPath] ?? fallback },
            set: { model.preferences[keyPath: keyPath] = $0 }
        )
    }

    private func optionalBoolBinding(
        _ keyPath: WritableKeyPath<AppPreferences, Bool?>,
        fallback: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { model.preferences[keyPath: keyPath] ?? fallback },
            set: { model.preferences[keyPath: keyPath] = $0 }
        )
    }

    private var credentialProfiles: [AppStoreConnectCredentialProfile] {
        model.preferences.appStoreConnectCredentialProfiles ?? []
    }

    private func profileTextBinding(
        _ profileID: UUID,
        keyPath: WritableKeyPath<AppStoreConnectCredentialProfile, String>
    ) -> Binding<String> {
        Binding(
            get: {
                credentialProfiles.first(where: { $0.id == profileID })?[keyPath: keyPath] ?? ""
            },
            set: { value in
                var profiles = credentialProfiles
                guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
                profiles[index][keyPath: keyPath] = value
                model.preferences.appStoreConnectCredentialProfiles = profiles
            }
        )
    }

    private func importPrivateKey(profileID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an App Store Connect private key")
        panel.prompt = L10n.text("Import")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let privateKey = try String(contentsOf: url, encoding: .utf8)
            model.saveAppStoreConnectPrivateKey(privateKey, profileID: profileID)
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func statusSymbol(for state: PublishingLogSession.State) -> String {
        switch state {
        case .inProgress: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private func statusColor(for state: PublishingLogSession.State) -> Color {
        switch state {
        case .inProgress: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private func statusTitle(for state: PublishingLogSession.State) -> String {
        switch state {
        case .inProgress: L10n.text("Publication in progress")
        case .succeeded: L10n.text("Publication completed successfully")
        case .failed: L10n.text("Publication failed")
        case .cancelled: L10n.text("Publication canceled")
        }
    }
}
