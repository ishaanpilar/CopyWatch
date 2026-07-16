import Foundation

/// Source ↔ destination diffing. Used to rescue partial (e.g. Finder) copies at
/// job start and to power the standalone Compare tool.
enum Reconciler {
    /// mtime tolerance: FAT/exFAT store modification times at 2s resolution.
    static let mtimeTolerance: TimeInterval = 2.0

    enum MatchState {
        case match          // complete at destination
        case partial        // destination file smaller than source
        case differs        // same size but mtime/hash mismatch
        case missing        // not at destination
    }

    /// Classify one source record against the destination root (quick: size + mtime).
    static func classify(_ record: FileRecord, destRoot: URL) -> MatchState {
        let dest = destRoot.appendingPathComponent(record.relativePath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
              let size = attrs[.size] as? Int64 else {
            return .missing
        }
        if size < record.size { return .partial }
        if size > record.size { return .differs }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        if abs(mtime.timeIntervalSince(record.modificationDate)) <= mtimeTolerance {
            return .match
        }
        return .differs
    }

    /// Pre-copy reconcile: mark already-complete destination files as skipped so a
    /// job pointed at a partial (Finder) copy only moves what's actually needed.
    /// Partial/differing files stay pending — the copy engine sorts them out.
    static func reconcile(job: inout CopyJob, destRoot: URL) {
        for i in job.files.indices where !job.files[i].isDone {
            if case .match = classify(job.files[i], destRoot: destRoot) {
                job.files[i].status = .skipped
                job.files[i].bytesCopied = job.files[i].size
                job.skippedFiles += 1
                job.doneFiles += 1
                job.doneBytes += job.files[i].size
            }
        }
    }

    /// Standalone comparison of two trees. `deep` hashes both sides of every
    /// candidate match; quick mode compares size + mtime only.
    static func compare(
        a: URL, b: URL, deep: Bool,
        progress: ((String) -> Void)? = nil
    ) throws -> ComparisonRecord {
        progress?("Scanning \(a.lastPathComponent)…")
        let filesA = try Scanner.scan(root: a)
        progress?("Scanning \(b.lastPathComponent)…")
        let filesB = try Scanner.scan(root: b)

        var record = ComparisonRecord(
            id: UUID(), date: Date(), pathA: a.path, pathB: b.path, deep: deep)
        record.filesA = filesA.count
        record.bytesA = filesA.reduce(0) { $0 + $1.size }
        record.filesB = filesB.count
        record.bytesB = filesB.reduce(0) { $0 + $1.size }

        let byPathB = Dictionary(uniqueKeysWithValues: filesB.map { ($0.relativePath, $0) })
        var seenInA = Set<String>()

        for (index, fa) in filesA.enumerated() {
            try Task.checkCancellation()
            seenInA.insert(fa.relativePath)
            guard let fb = byPathB[fa.relativePath] else {
                record.missing.append(fa.relativePath)
                continue
            }
            if fa.size != fb.size {
                record.differing.append(fa.relativePath)
                continue
            }
            if deep {
                progress?("Hashing \(index + 1)/\(filesA.count): \(fa.relativePath)")
                let ha = try FileHasher.sha256(of: a.appendingPathComponent(fa.relativePath))
                let hb = try FileHasher.sha256(of: b.appendingPathComponent(fa.relativePath))
                if ha != hb {
                    record.differing.append(fa.relativePath)
                    continue
                }
            } else if abs(fa.modificationDate.timeIntervalSince(fb.modificationDate)) > mtimeTolerance {
                record.differing.append(fa.relativePath)
                continue
            }
            record.matched += 1
        }
        record.extras = filesB.map(\.relativePath).filter { !seenInA.contains($0) }
        return record
    }
}
