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
    }
}
