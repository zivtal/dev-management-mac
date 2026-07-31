import SwiftUI

@main
struct DevReinstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(Text("Dev Reinstaller"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        }
    }

    private var menuBarSymbol: String {
        if model.progress != nil { return "arrow.triangle.2.circlepath" }
        return "square.stack.3d.up.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
