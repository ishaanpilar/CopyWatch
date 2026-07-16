import Foundation

/// One drive speed/health measurement, kept in history so a drive slowing down
/// over time (an early failure signal) becomes visible.
struct BenchmarkResult: Codable, Identifiable, Hashable {
    let id: UUID
    var date: Date
    var volumeName: String
    var volumePath: String
    var volumeUUID: String?

    var writeBytesPerSec: Double
    var readBytesPerSec: Double
    var testBytes: Int64

    /// From `diskutil` where available.
    var smartStatus: String?      // e.g. "Verified", "Not Supported"
    var connection: String?       // e.g. "USB", "Thunderbolt", "PCI-Express"
    var isSolidState: Bool?

    /// Speed-based rating (SSDs and spinning disks judged on different scales).
    var rating: String {
        let write = writeBytesPerSec / 1_000_000  // MB/s
        if isSolidState == false {
            // Spinning disk expectations.
            switch write {
            case 150...: return "Excellent"
            case 90..<150: return "Good"
            case 45..<90: return "Fair"
            default: return "Slow"
            }
        }
        switch write {
        case 700...: return "Excellent"
        case 350..<700: return "Good"
        case 120..<350: return "Fair"
        default: return "Slow"
        }
    }
}
