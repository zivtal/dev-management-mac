import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem { Label("General", systemImage: "gearshape") }

            ProjectsSettingsView()
                .environmentObject(model)
                .tabItem { Label("Applications", systemImage: "app.badge") }

            ActivityView()
                .environmentObject(model)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }

            DevicesSettingsView()
                .environmentObject(model)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 560)
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            ),
            actions: { Button("OK") { model.presentedError = nil } },
            message: { Text(model.presentedError ?? "") }
        )
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Automatic installation") {
                Toggle("Check and install automatically", isOn: $model.preferences.automationEnabled)
                Stepper(value: $model.preferences.reinstallAfterDays, in: 1...30) {
                    LabeledContent("Reinstall interval") {
                        Text(L10n.format("%d days", model.preferences.reinstallAfterDays))
                    }
                }
                Text("The interval is tracked separately for each application and each selected iPhone or iPad. A newly added application is installed at the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background operation") {
                Toggle(
                    "Open Dev Reinstaller at login",
                    isOn: Binding(
                        get: { model.preferences.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Text("The application has no Dock window and remains available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("settings.launch_at_login.default_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle(
                    "Notify after every successful application installation",
                    isOn: Binding(
                        get: { model.preferences.notificationsEnabled != false },
                        set: { model.preferences.notificationsEnabled = $0 }
                    )
                )
                Text("Each notification includes the application, device name and model, and connection type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersion).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("%@ (build %@)", version, build)
    }
}

private struct DevicesSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected devices")
                        .font(.title2.bold())
                    Text("Choose installation devices separately for each application in the Applications tab.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshNow()
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingDevices || model.progress != nil)
            }

            if model.connectedDevices.isEmpty {
                ContentUnavailableView(
                    "No connected devices",
                    systemImage: "iphone.slash",
                    description: Text("USB and Wi‑Fi connections are supported. For Wi‑Fi, enable Connect via network for the device in Xcode.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.connectedDevices) {
                    TableColumn("Device") { device in
                        Label(device.name, systemImage: device.symbolName)
                            .fontWeight(.medium)
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Model") { device in
                        Text(device.model ?? L10n.text("Unknown"))
                    }
                    .width(min: 170, ideal: 220)

                    TableColumn("System") { device in
                        Text(device.platformDescription)
                    }
                    .width(min: 75, ideal: 90)

                    TableColumn("Connection") { device in
                        Text(device.connectionDescription)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Installation") { device in
                        if device.supportsIOSAppInstallation {
                            Text("Choose per application")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Companion device")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 115, ideal: 140)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding()
    }
}
