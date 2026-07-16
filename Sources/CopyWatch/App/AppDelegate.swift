import AppKit
import UserNotifications

/// Owns the single AppState instance (created before the SwiftUI scene
/// builds), registers CopyWatch as a Finder Service, and handles the action
/// buttons on completion notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
    }

    // MARK: Notification action buttons

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let idStr = info["jobID"] as? String, let id = UUID(uuidString: idStr) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            appState.handleNotificationAction(action, jobID: id)
        }
    }

    /// Files dropped on the Dock icon or opened via `open -a CopyWatch …` —
    /// same destination prompt as an in-window drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        appState.handleIncomingSources(urls.map(\.path))
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Invoked by macOS when the user picks Finder ▸ right-click ▸ Services ▸
    /// "Copy with CopyWatch". Declared in Info.plist's NSServices; the
    /// selector name must match NSMessage there exactly.
    @objc func copyWithCopyWatch(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        var paths: [String] = []
        // Modern file-URL reading first; fall back to the legacy filenames type.
        if let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            paths = urls.map(\.path)
        }
        if paths.isEmpty,
           let items = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            paths = items
        }
        guard !paths.isEmpty else {
            error.pointee = "CopyWatch couldn't read the selected files." as NSString
            return
        }
        // Services run on the main thread and this class is @MainActor.
        appState.handleIncomingSources(paths)
        NSApp.activate(ignoringOtherApps: true)
    }
}
