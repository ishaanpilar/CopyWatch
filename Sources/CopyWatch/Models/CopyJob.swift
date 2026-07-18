import Foundation

enum JobStatus: String, Codable {
    case scanning, ready, queued, running, paused, waitingForVolume
    case interrupted, completed, completedWithErrors, cancelled

    var isActive: Bool {
        switch self {
        case .scanning, .ready, .queued, .running, .paused, .waitingForVolume, .interrupted:
            return true
        case .completed, .completedWithErrors, .cancelled:
            return false
        }
    }

    var label: String {
        switch self {
        case .scanning: "Scanning"
        case .ready: "Ready"
        case .queued: "Queued"
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

/// One destination of a (possibly multi-target) copy job.
struct JobDestination: Codable, Hashable {
    var volume: VolumeRef
    /// Absolute root, already including the source folder name.
    var path: String
}

/// A copy job: one source tree copied to one or more destinations, with a full manifest.
struct CopyJob: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String

    var sourceVolume: VolumeRef
    var destVolume: VolumeRef
    /// Root of the tree being copied, e.g. /Volumes/CARD-A/DCIM
    /// (display-only for device jobs).
    var sourcePath: String
    /// Primary destination root the tree is copied into (already includes the
    /// source folder name), e.g. /Volumes/Backup/DCIM
    var destPath: String

    /// Additional destinations for a multi-backup (one source → many verified
    /// copies in a single read pass). Empty for a normal single-destination
    /// job, so old saved jobs decode unchanged.
    var extraDestinations: [JobDestination] = []

    /// All destinations in order, primary first.
    var allDestinations: [JobDestination] {
        [JobDestination(volume: destVolume, path: destPath)] + extraDestinations
    }

    var isMultiDestination: Bool { !extraDestinations.isEmpty }

    /// Set for iPhone/camera jobs: the device's persistent ID (ImageCaptureCore).
    /// The source is then the device's media catalog, not a filesystem path.
    var sourceDeviceID: String?
    var isDeviceJob: Bool { sourceDeviceID != nil }

    /// Set when the user reclaimed the source drive: the copied originals were
    /// moved to the Trash (never permanently deleted). Optional so old job
    /// files keep decoding.
    var sourceTrashedAt: Date?
    var sourceTrashedCount: Int?

    /// True when the user picked individual files (or a mixed selection)
    /// rather than one folder — enables per-item Get Info comparisons.
    /// Optional so pre-existing job files keep decoding.
    var isFileSelection: Bool?

    /// The production this copy belongs to. All three are Optional so job
    /// files from before Projects existed keep decoding (a missing key on a
    /// non-optional field would silently drop the record).
    var projectID: UUID?
    /// Display name within the project's Source Media list: "Sony FX3 Card 2".
    var sourceLabel: String?
    /// Folder inside the project the copy landed in: "01_Footage/Card 2".
    var projectFolder: String?

    var status: JobStatus = .scanning
    var verifyAfterCopy: Bool = true
    /// Checksum algorithm for copy + verify. Optional for back-compat: jobs
    /// saved before this field decode as nil, which `checksumAlgorithm` reads
    /// as SHA-256 (what those jobs actually used). Never make this non-optional
    /// — a missing key would make every old job file fail to decode and vanish.
    var checksumAlgorithmRaw: ChecksumAlgorithm?
    var checksumAlgorithm: ChecksumAlgorithm {
        get { checksumAlgorithmRaw ?? .sha256 }
        set { checksumAlgorithmRaw = newValue }
    }
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
    /// Throughput profile in MB/s, one sample ~per second, capped — drives the
    /// live speed graph and the slowdown analysis.
    var speedHistory: [Double] = []

    var files: [FileRecord] = []

    var averageFileBytes: Int64 { totalFiles > 0 ? totalBytes / Int64(totalFiles) : 0 }

    var fractionDone: Double {
        totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
    }

    var pendingFiles: Int { totalFiles - doneFiles - failedFiles }

    var etaSeconds: Double? {
        guard bytesPerSecond > 1, status == .running else { return nil }
        return Double(totalBytes - doneBytes) / bytesPerSecond
    }

    /// Rebuild the running counters from the manifest (used by the engines and
    /// after a re-verification pass, so drift never accumulates).
    mutating func recomputeCounters() {
        var done = 0, skipped = 0, verified = 0, failed = 0
        var bytes: Int64 = 0
        for f in files {
            switch f.status {
            case .copied, .verified, .skipped:
                done += 1
                bytes += f.size
                if f.status == .skipped { skipped += 1 }
                if f.status == .verified { verified += 1 }
            case .failed:
                failed += 1
            case .pending, .copying:
                bytes += f.bytesCopied
            }
        }
        doneFiles = done
        doneBytes = bytes
        skippedFiles = skipped
        verifiedFiles = verified
        failedFiles = failed
    }

    static func defaultName(source: String, dest: String) -> String {
        let s = (source as NSString).lastPathComponent
        let d = URL(fileURLWithPath: dest).deletingLastPathComponent().lastPathComponent
        return "\(s) → \(d)"
    }
}
