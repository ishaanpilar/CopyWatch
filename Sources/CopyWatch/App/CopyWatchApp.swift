import SwiftUI

struct CopyWatchApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear {
                    Notifier.requestPermission()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    appState.flush()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CopyWatch") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Created by Ishaan Pilar\n\nVerified, resumable file backups for filmmakers — checksummed copy jobs, interrupted-copy rescue, folder comparison, and iPhone backup.\n\ngithub.com/ishaanpilar/CopyWatch",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]),
                        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                            "© 2026 Ishaan Pilar",
                    ])
                }
            }
        }
    }
}
