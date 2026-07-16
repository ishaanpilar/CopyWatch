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
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
