import Foundation

enum JobStatus: String, Codable {
    case scanning, ready, running, paused, waitingForVolume
    case interrupted, completed, completedWithErrors, cancelled

    var isActive: Bool {
        switch self {
        case .scanning, .ready, .running, .paused, .waitingForVolume, .interrupted:
            return true
        case .completed, .completedWithErrors, .cancelled:
            return false
        }
    }

    var label: String {
        switch self {
        case .scanning: "Scanning"
        case .ready: "Ready"
        case .running: "Copying"
        case .paused: "Paused"
        case .waitingForVolume: "Waiting for drive"
        case .interrupted: "Interrupted"
        case .completed: "Completed"
        case .completedWithErrors: "Completed with errors"
        case .cancelled: "Cancelled"
        }
    }
}

/// A copy job: one source tree being copied to one destination, with a full manifest.
struct CopyJob: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String

    var sourceVolume: VolumeRef
    var destVolume: VolumeRef
    /// Root of the tree being copied, e.g. /Volumes/CARD-A/DCIM
    /// (display-only for device jobs).
    var sourcePath: String
    /// Root the tree is copied into (already includes the source folder name),
    /// e.g. /Volumes/Backup/DCIM
    var destPath: String

    /// Set for iPhone/camera jobs: the device's persistent ID (ImageCaptureCore).
    /// The source is then the device's media catalog, not a filesystem path.
    var sourceDeviceID: String?
    var isDeviceJob: Bool { sourceDeviceID != nil }

    var status: JobStatus = .scanning
    var verifyAfterCopy: Bool = true
    var createdAt: Date = Date()
    var completedAt: Date?
    var statusMessage: String?

    // Totals from the scan.
    var totalFiles: Int = 0
    var totalBytes: Int64 = 0

    // Running counters, maintained incrementally by the engine.
    var doneFiles: Int = 0
    var doneBytes: Int64 = 0
    var skippedFiles: Int = 0
    var verifiedFiles: Int = 0
    var failedFiles: Int = 0

    // Transient progress info (persisted harmlessly).
    var currentFile: String?
    var bytesPerSecond: Double = 0

    var files: [FileRecord] = []

    var fractionDone: Double {
        totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
    }

    var pendingFiles: Int { totalFiles - doneFiles - failedFiles }

    var etaSeconds: Double? {
        guard bytesPerSecond > 1, status == .running else { return nil }
        return Double(totalBytes - doneBytes) / bytesPerSecond
    }

    static func defaultName(source: String, dest: String) -> String {
        let s = (source as NSString).lastPathComponent
        let d = URL(fileURLWithPath: dest).deletingLastPathComponent().lastPathComponent
        return "\(s) → \(d)"
    }
}
