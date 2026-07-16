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
    /// Human-readable failure title (from CopyDiagnosis).
    var error: String?
    /// Concrete "how to fix it" hint that pairs with `error`.
    var errorFix: String?
    /// SF Symbol for the failure category.
    var errorIcon: String?

    var isDone: Bool {
        status == .copied || status == .verified || status == .skipped
    }

    mutating func applyFailure(_ diagnosis: CopyDiagnosis) {
        status = .failed
        error = diagnosis.title
        errorFix = diagnosis.fix
        errorIcon = diagnosis.icon
    }
}
