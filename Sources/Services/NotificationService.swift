import Foundation
import UserNotifications

enum InstallationNotificationText {
    static func title(project: ManagedProject) -> String {
        L10n.format("%@ reinstalled successfully", project.displayName)
    }

    static func body(project: ManagedProject, device: ConnectedDevice) -> String {
        L10n.format(
            "%@ — %@: %@ was reinstalled via %@.",
            device.name,
            device.model ?? L10n.text("iPhone"),
            project.displayName,
            device.connectionDescription
        )
    }
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
    }

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("DevReinstaller notification permission error: %@", error.localizedDescription)
            }
        }
    }

    func notifySuccessfulInstallation(
        project: ManagedProject,
        device: ConnectedDevice,
        applicationIconURL: URL?
    ) {
        let content = UNMutableNotificationContent()
        content.title = InstallationNotificationText.title(project: project)
        content.body = InstallationNotificationText.body(project: project, device: device)
        content.sound = .default
        if let applicationIconURL {
            do {
                content.attachments = [try UNNotificationAttachment(
                    identifier: "installed-application-icon",
                    url: applicationIconURL
                )]
            } catch {
                NSLog(
                    "DevReinstaller could not attach the installed application icon: %@",
                    error.localizedDescription
                )
            }
        }

        let request = UNNotificationRequest(
            identifier: "install-success-\(project.id.uuidString)-\(device.udid)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("DevReinstaller could not deliver notification: %@", error.localizedDescription)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
