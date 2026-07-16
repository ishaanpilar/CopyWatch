import Foundation
import CryptoKit

enum FileHasher {
    static let chunkSize = 8 * 1024 * 1024

    /// Streaming SHA-256 of a whole file (or its first `limit` bytes).
    /// Checks for task cancellation between chunks.
    static func sha256(of url: URL, limit: Int64? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(chunkSize), remaining))
            guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
