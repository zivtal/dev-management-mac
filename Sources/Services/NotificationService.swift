import Foundation
import UserNotifications

struct NotificationAttachmentCopy: Equatable {
    let fileURL: URL
    let directoryURL: URL
}

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

    static func macOSBody(project: ManagedProject) -> String {
        L10n.format("%@ was rebuilt, installed in Applications, and relaunched on this Mac.", project.displayName)
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
                NSLog("DevManagement notification permission error: %@", error.localizedDescription)
            }
        }
    }

    func notifySuccessfulInstallation(
        project: ManagedProject,
        device: ConnectedDevice,
        applicationIconURL: URL?
    ) {
        deliverSuccessfulInstallationNotification(
            identifier: "install-success-\(project.id.uuidString)-\(device.udid)-\(UUID().uuidString)",
            title: InstallationNotificationText.title(project: project),
            body: InstallationNotificationText.body(project: project, device: device),
            applicationIconURL: applicationIconURL
        )
    }

    func notifySuccessfulMacOSInstallation(
        project: ManagedProject,
        applicationIconURL: URL?
    ) {
        deliverSuccessfulInstallationNotification(
            identifier: "install-success-\(project.id.uuidString)-mac-\(UUID().uuidString)",
            title: InstallationNotificationText.title(project: project),
            body: InstallationNotificationText.macOSBody(project: project),
            applicationIconURL: applicationIconURL
        )
    }

    private func deliverSuccessfulInstallationNotification(
        identifier: String,
        title: String,
        body: String,
        applicationIconURL: URL?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var attachmentDirectoryURL: URL?
        if let applicationIconURL {
            do {
                let attachmentCopy = try Self.copyForNotificationAttachment(
                    sourceURL: applicationIconURL
                )
                attachmentDirectoryURL = attachmentCopy.directoryURL
                content.attachments = [try UNNotificationAttachment(
                    identifier: "installed-application-icon",
                    url: attachmentCopy.fileURL
                )]
            } catch {
                if let attachmentDirectoryURL {
                    try? FileManager.default.removeItem(at: attachmentDirectoryURL)
                }
                NSLog(
                    "DevManagement could not attach the installed application icon: %@",
                    error.localizedDescription
                )
            }
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let attachmentDirectoryURL {
                try? FileManager.default.removeItem(at: attachmentDirectoryURL)
            }
            if let error {
                NSLog("DevManagement could not deliver notification: %@", error.localizedDescription)
            }
        }
    }

    static func copyForNotificationAttachment(
        sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> NotificationAttachmentCopy {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Notification-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(
            sourceURL.lastPathComponent.isEmpty ? "ApplicationIcon.png" : sourceURL.lastPathComponent
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: fileURL)
            return NotificationAttachmentCopy(fileURL: fileURL, directoryURL: directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
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
