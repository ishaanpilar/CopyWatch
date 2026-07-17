import Foundation
import CryptoKit

enum FileHasher {
    static let chunkSize = 8 * 1024 * 1024

    /// Streaming checksum of a whole file (or its first `limit` bytes) using the
    /// chosen algorithm. Checks for task cancellation between chunks.
    ///
    /// Pass `bypassCache: true` for verification reads: `F_NOCACHE` makes the
    /// kernel read from the device instead of serving the bytes we just wrote
    /// back out of the unified buffer cache — so a bad cable or failing flash
    /// that corrupted the write is actually caught, not masked by RAM.
    static func hash(
        of url: URL, algorithm: ChecksumAlgorithm = .sha256,
        limit: Int64? = nil, bypassCache: Bool = false
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassCache { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var hasher = algorithm.makeHasher()
        var remaining = limit ?? .max
        while remaining > 0 {
            try Task.checkCancellation()
            // Each `read` returns an autoreleased Data; without draining per
            // chunk, the backing memory piles up until the whole task ends —
            // which, over a big deep compare, meant tens of GB of RAM. The pool
            // frees every chunk as soon as it's hashed.
            let n: Int = try autoreleasepool {
                let want = Int(min(Int64(chunkSize), remaining))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { return 0 }
                hasher.update(data)
                return data.count
            }
            if n == 0 { break }
            remaining -= Int64(n)
        }
        return hasher.finalizedHex()
    }

    /// Streaming SHA-256 convenience — used where the algorithm is fixed
    /// (dedup comparisons, deep Compare, restore re-checks).
    static func sha256(of url: URL, limit: Int64? = nil, bypassCache: Bool = false) throws -> String {
        try hash(of: url, algorithm: .sha256, limit: limit, bypassCache: bypassCache)
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
