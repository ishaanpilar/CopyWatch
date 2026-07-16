import Foundation

/// Result of a standalone folder-vs-folder comparison, kept in History.
struct ComparisonRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var date: Date
    var pathA: String
    var pathB: String
    var deep: Bool

    var filesA: Int = 0
    var bytesA: Int64 = 0
    var filesB: Int = 0
    var bytesB: Int64 = 0

    /// Relative paths present in A but not in B.
    var missing: [String] = []
    /// Relative paths present on both sides but different (size, or hash in deep mode).
    var differing: [String] = []
    /// Relative paths present in B but not in A.
    var extras: [String] = []
    var matched: Int = 0

    var isIdentical: Bool { missing.isEmpty && differing.isEmpty && extras.isEmpty }
}
