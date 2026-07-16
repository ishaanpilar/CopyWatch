import AppKit

/// Owns the single AppState instance (created before the SwiftUI scene
/// builds) and registers CopyWatch as a Finder Service, so "Copy with
/// CopyWatch" appears in Finder's right-click menu under Services for any
/// selected file or folder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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
        _ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        var paths: [String] = []
        if let items = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            paths = items
        } else if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            paths = urls.map(\.path)
        }
        guard !paths.isEmpty else {
            error.pointee = "CopyWatch couldn't find any files in that selection." as NSString
            return
        }
        Task { @MainActor [appState] in
            appState.handleIncomingSources(paths)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
