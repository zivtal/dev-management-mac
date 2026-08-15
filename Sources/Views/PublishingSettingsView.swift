import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PublishingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var openAIAPIKey = ""

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
                        .frame(width: 220)
                }
                Text("On Publish, the app sends the application name, version, identifiers, and excerpts from its README or supported project manifest to the OpenAI Responses API. Swift and Objective-C source code and credentials are not uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App Store Connect API") {
                LabeledContent("Issuer ID") {
                    TextField("Issuer ID", text: optionalTextBinding(\.appStoreConnectIssuerID))
                        .frame(width: 340)
                }
                LabeledContent("Key ID") {
                    TextField("Key ID", text: optionalTextBinding(\.appStoreConnectKeyID))
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
                        importPrivateKey()
                    }
                }
                Text("Create a team App Store Connect API key with permission to manage apps, builds, metadata, screenshots, and submissions. The private key is stored only in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Publication") {
                LabeledContent("Store locale") {
                    TextField("en-US", text: optionalTextBinding(\.appStoreLocale, fallback: "en-US"))
                        .frame(width: 120)
                }
                LabeledContent("Copyright owner") {
                    TextField("2026 Company Name", text: optionalTextBinding(\.appStoreCopyright))
                        .frame(width: 340)
                }
                LabeledContent("Support URL") {
                    TextField("https://example.com/support", text: optionalTextBinding(\.appStoreSupportURL))
                        .frame(width: 340)
                }
                Toggle(
                    "Submit the uploaded version for App Review",
                    isOn: optionalBoolBinding(\.appStoreSubmitForReview, fallback: true)
                )
                Toggle(
                    "Release automatically after Apple approves it",
                    isOn: optionalBoolBinding(\.appStoreReleaseAutomatically, fallback: true)
                )
                Text("A project Screenshots folder is used first. Missing iPhone or iPad screenshots are captured from an available Simulator after launching the selected scheme. Existing App Store Connect screenshot sets are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func importPrivateKey() {
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
            model.saveAppStoreConnectPrivateKey(privateKey)
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
