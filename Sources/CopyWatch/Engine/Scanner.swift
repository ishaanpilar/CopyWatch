import Foundation

/// Recursively enumerates a source tree into a manifest of regular files.
enum Scanner {
    /// Filesystem junk that must never count toward a backup.
    static let junkNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".DocumentRevisions-V100", ".VolumeIcon.icns",
        ".com.apple.timemachine.donotpresent", "$RECYCLE.BIN", "System Volume Information",
    ]

    static func isJunk(_ name: String) -> Bool {
        junkNames.contains(name) || name.hasPrefix("._") || name.hasSuffix(".cwpart")
    }

    /// Scan `root`, reporting (files, bytes) progress periodically.
    static func scan(
        root: URL,
        progress: ((Int, Int64) -> Void)? = nil
    ) throws -> [FileRecord] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .nameKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.producesRelativePathURLs]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var records: [FileRecord] = []
        var bytes: Int64 = 0
        var lastReport = Date()

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            let name = values.name ?? url.lastPathComponent

            if values.isDirectory == true {
                if isJunk(name) { enumerator.skipDescendants() }
                continue
            }
            if isJunk(name) || values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }

            let size = Int64(values.fileSize ?? 0)
            records.append(FileRecord(
                relativePath: url.relativePath,
                size: size,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
            bytes += size

            if let progress, Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                progress(records.count, bytes)
            }
        }
        // Stable, human-sensible order.
        records.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        progress?(records.count, bytes)
        return records
    }
}
