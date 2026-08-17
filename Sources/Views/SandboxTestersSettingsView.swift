import SwiftUI

struct SandboxTestersSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedProfileID: UUID?
    @State private var testers: [SandboxTester] = []
    @State private var isLoading = false
    @State private var resettingTesterID: String?
    @State private var pendingResetTester: SandboxTester?
    @State private var completedResetTester: SandboxTester?

    init(selectedProfileID: UUID? = nil) {
        _selectedProfileID = State(initialValue: selectedProfileID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            credentialControls

            if !credentialIsComplete {
                ContentUnavailableView(
                    "App Store Connect API not configured",
                    systemImage: "key.slash",
                    description: Text("Complete the selected API profile in Publishing settings before loading sandbox accounts.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading && testers.isEmpty {
                ProgressView("Loading sandbox accounts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if testers.isEmpty {
                ContentUnavailableView(
                    "No sandbox accounts loaded",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Refresh to load the Sandbox Apple Accounts available to this App Store Connect team.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                testerTable
            }
        }
        .padding()
        .confirmationDialog(
            "Reset sandbox purchases?",
            isPresented: Binding(
                get: { pendingResetTester != nil },
                set: { if !$0 { pendingResetTester = nil } }
            ),
            presenting: pendingResetTester
        ) { tester in
            Button("Reset Purchases", role: .destructive) {
                resetPurchases(for: tester)
            }
            Button("Cancel", role: .cancel) {}
        } message: { tester in
            Text(L10n.format(
                "This permanently clears all sandbox in-app purchase and subscription history for %@ across this App Store Connect team. Production purchases are not affected.",
                tester.accountName
            ))
        }
        .alert(
            "Sandbox purchases reset",
            isPresented: Binding(
                get: { completedResetTester != nil },
                set: { if !$0 { completedResetTester = nil } }
            ),
            presenting: completedResetTester
        ) { _ in
            Button("OK") {}
        } message: { tester in
            Text(L10n.format(
                "Purchase history for %@ was cleared. Sign out of the Sandbox Apple Account on the test device, then sign in again before retesting.",
                tester.accountName
            ))
        }
        .onChange(of: selectedProfileID) {
            testers = []
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Sandbox purchases")
                .font(.title2.bold())
            Text("Reset a Sandbox Apple Account so subscriptions and StoreKit introductory offers can be tested again. The reset applies to every sandbox purchase on the selected developer team, not only one application.")
                .foregroundStyle(.secondary)
            Text("App-managed trials based on original download dates are not reset by this action.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var credentialControls: some View {
        HStack {
            Picker("App Store Connect API", selection: $selectedProfileID) {
                ForEach(model.appStoreConnectCredentials, id: \.profileID) { credential in
                    Text(credential.name).tag(credential.profileID)
                }
            }
            .frame(maxWidth: 420)

            Button {
                loadTesters()
            } label: {
                Label("Refresh accounts", systemImage: "arrow.clockwise")
            }
            .disabled(!credentialIsComplete || isLoading || resettingTesterID != nil)
        }
    }

    private var testerTable: some View {
        Table(testers) {
            TableColumn("Account") { tester in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tester.displayName).fontWeight(.medium)
                    Text(tester.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 220, ideal: 280)

            TableColumn("Storefront") { tester in
                Text(tester.territory ?? L10n.text("Unknown"))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Renewal rate") { tester in
                Text(tester.subscriptionRenewalDescription)
            }
            .width(min: 120, ideal: 150)

            TableColumn("") { tester in
                if resettingTesterID == tester.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Reset Purchases", role: .destructive) {
                        pendingResetTester = tester
                    }
                    .disabled(resettingTesterID != nil)
                }
            }
            .width(min: 120, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var credentialIsComplete: Bool {
        model.appStoreConnectCredentialIsComplete(profileID: selectedProfileID)
    }

    private func loadTesters() {
        isLoading = true
        Task {
            do {
                testers = try await model.loadSandboxTesters(profileID: selectedProfileID)
            } catch {
                model.presentedError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func resetPurchases(for tester: SandboxTester) {
        resettingTesterID = tester.id
        Task {
            do {
                try await model.clearSandboxPurchaseHistory(
                    for: tester,
                    profileID: selectedProfileID
                )
                completedResetTester = tester
            } catch {
                model.presentedError = error.localizedDescription
            }
            resettingTesterID = nil
        }
    }
}
