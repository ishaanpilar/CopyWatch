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

    /// Smart duplicate detection ("hash when in doubt"): an instant `.match`
    /// when size AND mtime agree; when the size matches but the date is off
    /// (the ambiguous case), the two files are hashed to decide identity for
    /// real, so we never skip a genuinely different file nor needlessly recopy
    /// an identical one whose timestamp merely drifted. `sourceRoot` supplies
    /// the source file to hash against.
    static func classifyDeep(_ record: FileRecord, destRoot: URL, sourceRoot: URL) -> MatchState {
        let quick = classify(record, destRoot: destRoot)
        guard quick == .differs else { return quick }
        // Only the size-matches-but-date-differs case reaches here; resolve by hash.
        let dest = destRoot.appendingPathComponent(record.relativePath)
        let src = sourceRoot.appendingPathComponent(record.relativePath)
        guard let dh = try? FileHasher.sha256(of: dest),
              let sh = try? FileHasher.sha256(of: src) else {
            return .differs
        }
        return dh == sh ? .match : .differs
    }

    /// Pre-copy reconcile: mark files already complete at EVERY destination as
    /// skipped so a job only moves what's actually needed. With `deep`, the
    /// ambiguous size-match/date-mismatch case is resolved by hashing (smart
    /// duplicate detection) rather than assumed different.
    static func reconcile(job: inout CopyJob, destRoots: [URL], sourceRoot: URL?, deep: Bool) {
        for i in job.files.indices where !job.files[i].isDone {
            let completeEverywhere = destRoots.allSatisfy { root in
                let state = (deep && sourceRoot != nil)
                    ? classifyDeep(job.files[i], destRoot: root, sourceRoot: sourceRoot!)
                    : classify(job.files[i], destRoot: root)
                return state == .match
            }
            if completeEverywhere {
                job.files[i].status = .skipped
                job.files[i].bytesCopied = job.files[i].size
                job.skippedFiles += 1
                job.doneFiles += 1
                job.doneBytes += job.files[i].size
            }
        }
    }

    /// Single-root convenience (unchanged callers).
    static func reconcile(job: inout CopyJob, destRoot: URL) {
        reconcile(job: &job, destRoots: [destRoot], sourceRoot: nil, deep: false)
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
