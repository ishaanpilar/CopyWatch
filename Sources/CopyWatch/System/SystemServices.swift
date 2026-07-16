import Foundation
import IOKit.pwr_mgt
import UserNotifications

/// Keeps the Mac awake while copies run.
final class SleepBlocker {
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    func setActive(_ wanted: Bool) {
        guard wanted != active else { return }
        if wanted {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "CopyWatch is copying files" as CFString,
                &assertionID)
            active = (result == kIOReturnSuccess)
        } else {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }
}

/// Local notifications for job completion. No-ops when not running from an
/// app bundle (e.g. headless mode), where the notification API is unavailable.
enum Notifier {
    static let completeCategory = "BACKUP_COMPLETE"
    static let openFolderAction = "OPEN_FOLDER"
    static let viewReportAction = "VIEW_REPORT"
    static let recheckAction = "RECHECK"
    static let ejectAction = "EJECT"

    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
        registerCategories()
    }

    /// Buttons that appear on a "backup complete" notification.
    static func registerCategories() {
        guard available else { return }
        let openFolder = UNNotificationAction(
            identifier: openFolderAction, title: "Open Folder", options: [.foreground])
        let viewReport = UNNotificationAction(
            identifier: viewReportAction, title: "View Report", options: [.foreground])
        let recheck = UNNotificationAction(
            identifier: recheckAction, title: "Recheck", options: [])
        let eject = UNNotificationAction(
            identifier: ejectAction, title: "Eject Drive", options: [])
        let category = UNNotificationCategory(
            identifier: completeCategory,
            actions: [openFolder, viewReport, recheck, eject],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func notify(title: String, body: String) {
        post(title: title, body: body, category: nil, userInfo: [:])
    }

    /// A completion notification carrying the job ID so its action buttons can
    /// act on the right job.
    static func notifyCompletion(title: String, body: String, jobID: UUID) {
        post(title: title, body: body, category: completeCategory,
             userInfo: ["jobID": jobID.uuidString])
    }

    private static func post(title: String, body: String, category: String?, userInfo: [String: Any]) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
