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

    /// Scan an arbitrary selection of files and/or folders (from a multi-select
    /// Finder panel) into one manifest. Picks the lowest common ancestor
    /// directory of everything selected as the job's root, so:
    ///  - a single chosen folder behaves exactly like `scan(root:)` today.
    ///  - loose files chosen together (typically siblings in one folder) end up
    ///    with short, flat relative paths.
    ///  - a mixed/scattered selection still gets safe, collision-free paths,
    ///    since the root remains resolvable via VolumeRef for remount/resume.
    static func scanSelection(paths: [String]) throws -> (root: String, files: [FileRecord]) {
        precondition(!paths.isEmpty)
        let fm = FileManager.default

        if paths.count == 1 {
            let p = paths[0]
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            if isDir.boolValue {
                return (p, try scan(root: URL(fileURLWithPath: p)))
            }
            let parent = (p as NSString).deletingLastPathComponent
            return (parent, [try fileRecord(at: p)])
        }

        let root = commonAncestor(of: paths)
        var records: [FileRecord] = []
        for p in paths {
            try Task.checkCancellation()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let prefix = relativePath(of: p, from: root)
            if isDir.boolValue {
                let sub = try scan(root: URL(fileURLWithPath: p))
                records += sub.map { record in
                    FileRecord(
                        relativePath: prefix.isEmpty ? record.relativePath : "\(prefix)/\(record.relativePath)",
                        size: record.size, modificationDate: record.modificationDate)
                }
            } else {
                let name = (p as NSString).lastPathComponent
                if isJunk(name) { continue }
                records.append(try fileRecord(at: p, relativePath: prefix.isEmpty ? name : prefix))
            }
        }
        records.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return (root, records)
    }

    private static func fileRecord(at path: String, relativePath: String? = nil) throws -> FileRecord {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        return FileRecord(
            relativePath: relativePath ?? (path as NSString).lastPathComponent,
            size: size, modificationDate: mtime)
    }

    /// Path of `path` relative to ancestor `root` (both absolute), no leading slash.
    private static func relativePath(of path: String, from root: String) -> String {
        guard path.hasPrefix(root) else { return (path as NSString).lastPathComponent }
        var rel = String(path.dropFirst(root.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Lowest common ancestor directory of a set of absolute paths.
    private static func commonAncestor(of paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).pathComponents }) else { return "/" }
        for path in paths.dropFirst() {
            let other = (path as NSString).pathComponents
            var i = 0
            while i < common.count && i < other.count && common[i] == other[i] { i += 1 }
            common = Array(common[0..<i])
        }
        // The ancestor must be a directory, not one of the selected files itself
        // (only possible when every path is identical, which callers dedupe).
        return NSString.path(withComponents: common)
    }
}
