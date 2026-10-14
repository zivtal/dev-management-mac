import SwiftUI
import WebKit

struct AppleWebPage: NSViewRepresentable {
    let session: AppleWebSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct AppStoreAppCreationView: View {
    let project: ManagedProject
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = AppleWebSession.shared
    @State private var name: String
    @State private var sku: String
    @State private var locale = "en-US"
    @State private var includeIOS: Bool
    @State private var includeMac: Bool
    @State private var busy = false
    @State private var error: String?

    init(project: ManagedProject, completed: @escaping () -> Void) {
        self.project = project
        self.completed = completed
        _name = State(initialValue: project.displayName)
        _sku = State(initialValue: project.bundleIdentifier ?? project.scheme)
        _includeIOS = State(initialValue: !project.isMacOSApplication)
        _includeMac = State(initialValue: project.isMacOSApplication)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Create App in App Store Connect").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.disabled(busy)
            }
            Text("Sign in on Apple’s page and select the team used by this project. Apple handles your password and verification code. Complete any account agreements there before creating the app.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("App name", text: $name)
                TextField("Unique SKU", text: $sku)
                TextField("Primary locale", text: $locale).frame(width: 130)
            }.textFieldStyle(.roundedBorder).disabled(busy)
            HStack {
                Text(project.bundleIdentifier ?? "").font(.system(.caption, design: .monospaced))
                Spacer()
                Toggle("iPhone / iPad / Watch", isOn: $includeIOS)
                Toggle("Mac", isOn: $includeMac)
            }.disabled(busy)
            Text("Choose both platforms only when their store schemes use this same bundle ID. The Watch app and widget are uploaded with the iOS app.")
                .font(.caption).foregroundStyle(.secondary)
            AppleWebPage(session: session).frame(minWidth: 900, minHeight: 490)
            if let message = error ?? session.pageError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reload Apple Sign-In") { session.openApps() }.disabled(busy)
                Button("I Created It on Apple’s Page") { completed(); dismiss() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Create App") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !session.canUseSession || (!includeIOS && !includeMac))
            }
        }.padding(20)
    }

    private func create() {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                var platforms = Set<AppStorePlatform>()
                if includeIOS { platforms.insert(.iOS) }
                if includeMac { platforms.insert(.macOS) }
                _ = try await session.ensureApp(AppStoreAppRecord(
                    name: name, bundleID: project.bundleIdentifier ?? "", sku: sku, locale: locale,
                    version: project.marketingVersion ?? "1.0", platforms: platforms))
                completed()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
