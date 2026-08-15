import SwiftUI

@main
struct DevManagementApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(Text("Development Management"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        }
    }

    private var menuBarSymbol: String {
        if model.hasActiveWork { return "arrow.triangle.2.circlepath" }
        return "square.stack.3d.up.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
