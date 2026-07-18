import Foundation

/// Opens Finder's real Get Info windows — the thing people actually trust for
/// "did everything copy?". There's no public API for it, so this drives Finder
/// via AppleScript; the first use shows macOS's one-time "CopyWatch wants to
/// control Finder" prompt (NSAppleEventsUsageDescription supplies the reason).
enum FinderInfo {
    /// How many windows one click may open — beyond this it's clutter, not info.
    static let windowCap = 16

    /// Open a Get Info window for each existing path (capped, best effort).
    static func open(paths: [String]) {
        let existing = Array(paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .prefix(windowCap))
        guard !existing.isEmpty else { return }
        let lines = existing
            .map { "open information window of (POSIX file \"\(escape($0))\" as alias)" }
            .joined(separator: "\n    ")
        let script = """
        tell application "Finder"
            activate
            \(lines)
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()   // fire and forget; Finder does the rest
    }

    private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
