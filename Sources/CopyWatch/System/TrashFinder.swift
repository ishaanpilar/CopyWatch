import Foundation

/// Looks for a file that vanished from a destination inside the macOS Trash,
/// so a recheck can offer "restore" as an alternative to "recopy from
/// source" — the only option left once the source has also been cleaned up.
enum TrashFinder {
    /// Trash locations to search: the user's own Trash, plus the Trash on the
    /// destination's volume (external drives keep a separate `.Trashes/<uid>`).
    private static func trashDirectories(near destPath: String) -> [URL] {
        var dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
        if let volumeMount = try? URL(fileURLWithPath: destPath)
            .resourceValues(forKeys: [.volumeURLKey]).volume?.path {
            let volumeTrash = URL(fileURLWithPath: volumeMount)
                .appendingPathComponent(".Trashes/\(getuid())")
            if volumeTrash.path != dirs[0].path {
                dirs.append(volumeTrash)
            }
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Find a Trash item matching `fileName` (allowing macOS's automatic
    /// " 2", " 3"… collision suffixes) and, if given, an exact byte size.
    /// Searches a few levels deep — Trash items sit flat but this tolerates
    /// nested trashed folders too. Returns the newest match if several exist.
    static func find(fileName: String, size: Int64?, near destPath: String) -> URL? {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let fm = FileManager.default
        var candidates: [(url: URL, date: Date)] = []

        for dir in trashDirectories(near: destPath) {
            guard let enumerator = fm.enumerator(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var depth = 0
            for case let url as URL in enumerator {
                depth += 1
                if depth > 5000 { break }  // bounded — Trash can be large
                let name = url.lastPathComponent
                let matchesName = name == fileName || isNumberedVariant(name, of: base, ext: ext)
                guard matchesName else { continue }
                if let size,
                   let itemSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(itemSize) != size {
                    continue
                }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                candidates.append((url, date))
            }
        }
        return candidates.max(by: { $0.date < $1.date })?.url
    }

    /// "clip.mov" trashed twice becomes "clip.mov" and "clip 2.mov" — matches that pattern.
    private static func isNumberedVariant(_ name: String, of base: String, ext: String) -> Bool {
        let candidateBase = (name as NSString).deletingPathExtension
        let candidateExt = (name as NSString).pathExtension
        guard candidateExt == ext, candidateBase.hasPrefix(base + " ") else { return false }
        let suffix = candidateBase.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}
