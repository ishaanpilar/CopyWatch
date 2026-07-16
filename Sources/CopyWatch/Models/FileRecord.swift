import Foundation

enum FileStatus: String, Codable {
    case pending, copying, copied, verified, skipped, failed
}

/// One file in a job's manifest.
struct FileRecord: Codable, Identifiable, Hashable {
    var id: String { relativePath }

    let relativePath: String
    let size: Int64
    let modificationDate: Date

    var status: FileStatus = .pending
    /// Bytes confirmed at the destination (drives mid-file resume).
    var bytesCopied: Int64 = 0
    /// Hex SHA-256 of the source, computed while copying.
    var checksum: String?
    var error: String?

    var isDone: Bool {
        status == .copied || status == .verified || status == .skipped
    }
}
