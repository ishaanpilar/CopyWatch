import Foundation
import CryptoKit

/// Runs one job: chunked copy with streaming SHA-256, per-file verify,
/// pause/cancel, mid-file resume, and rescue of partial (Finder) copies.
///
/// All mutation happens on the engine's own task; progress leaves via
/// `onUpdate` snapshots (the caller decides threading and persistence).
final class JobEngine: @unchecked Sendable {
    private(set) var job: CopyJob
    private let onUpdate: @Sendable (CopyJob) -> Void

    private var task: Task<Void, Never>?
    private enum StopIntent { case pause, cancel, waitForVolume }
    private var stopIntent: StopIntent?

    private var lastEmit = Date.distantPast
    private var speedSamples: [(time: Date, bytes: Int64)] = []

    static let chunkSize = FileHasher.chunkSize
    static let partSuffix = ".cwpart"

    init(job: CopyJob, onUpdate: @escaping @Sendable (CopyJob) -> Void) {
        self.job = job
        self.onUpdate = onUpdate
    }

    // MARK: Control

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        stopIntent = nil
        task = Task.detached(priority: .userInitiated) { [self] in
            await run()
            task = nil
        }
    }

    func pause() { stop(.pause) }
    func cancel() { stop(.cancel) }
    /// Called when a volume this job uses was unmounted.
    func suspendForMissingVolume() { stop(.waitForVolume) }

    private func stop(_ intent: StopIntent) {
        if task != nil {
            stopIntent = intent
            task?.cancel()
        } else {
            // Not running (e.g. ready/interrupted): apply state directly.
            switch intent {
            case .pause: job.status = .paused
            case .cancel:
                job.status = .cancelled
                job.completedAt = Date()
            case .waitForVolume: job.status = .waitingForVolume
            }
            emit(force: true)
        }
    }

    // MARK: Main loop

    private func run() async {
        // Re-resolve roots; the drives may have remounted somewhere else.
        guard let src = job.sourceVolume.resolve(job.sourcePath) else {
            return finishWaiting("Source drive “\(job.sourceVolume.name)” is not connected.")
        }
        job.sourcePath = src
        let destParent = (job.destPath as NSString).deletingLastPathComponent
        guard let destParentResolved = job.destVolume.resolve(destParent) else {
            return finishWaiting("Destination drive “\(job.destVolume.name)” is not connected.")
        }
        job.destPath = (destParentResolved as NSString)
            .appendingPathComponent((job.destPath as NSString).lastPathComponent)

        let srcRoot = URL(fileURLWithPath: job.sourcePath)
        let destRoot = URL(fileURLWithPath: job.destPath)
        do {
            try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        } catch {
            return finishWaiting("Cannot create destination: \(error.localizedDescription)")
        }

        // A file interrupted mid-copy resumes from its partial data.
        for i in job.files.indices where job.files[i].status == .copying {
            job.files[i].status = .pending
        }
        recomputeCounters()

        // Recognize everything already complete at the destination
        // (our own previous run, or a dead Finder copy being rescued).
        job.status = .running
        job.statusMessage = "Checking what's already at the destination…"
        emit(force: true)
        Reconciler.reconcile(job: &job, destRoot: destRoot)
        job.statusMessage = nil
        speedSamples.removeAll()
        emit(force: true)

        for i in job.files.indices where !job.files[i].isDone && job.files[i].status != .failed {
            do {
                try Task.checkCancellation()
                try copyOneFile(at: i, srcRoot: srcRoot, destRoot: destRoot)
            } catch is CancellationError {
                return finishStopped()
            } catch {
                if volumeVanished(srcRoot: srcRoot, destRoot: destRoot) {
                    job.files[i].status = .pending
                    return finishWaiting("A drive disconnected mid-copy. Reconnect it to resume.")
                }
                job.files[i].status = .failed
                job.files[i].error = error.localizedDescription
                job.failedFiles += 1
                emit(force: true)
            }
        }

        job.currentFile = nil
        job.bytesPerSecond = 0
        job.completedAt = Date()
        job.status = job.failedFiles > 0 ? .completedWithErrors : .completed
        job.statusMessage = job.failedFiles > 0
            ? "\(job.failedFiles) file(s) failed — see the file list."
            : nil
        emit(force: true)
    }

    // MARK: One file

    private func copyOneFile(at index: Int, srcRoot: URL, destRoot: URL) throws {
        let record = job.files[index]
        let srcURL = srcRoot.appendingPathComponent(record.relativePath)
        let destURL = destRoot.appendingPathComponent(record.relativePath)
        let partURL = destURL.appendingPathExtension(String(Self.partSuffix.dropFirst()))
        let fm = FileManager.default

        job.files[index].status = .copying
        job.currentFile = record.relativePath
        emit(force: true)

        try fm.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Adopt partial data: our own .cwpart, or a smaller file left behind by a
        // dead Finder copy (renamed to .cwpart so we never expose incomplete files).
        if !fm.fileExists(atPath: partURL.path), fm.fileExists(atPath: destURL.path) {
            let attrs = try fm.attributesOfItem(atPath: destURL.path)
            let destSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if destSize < record.size {
                try fm.moveItem(at: destURL, to: partURL)
            } else {
                // Same size but reconcile said it differs (mtime/hash) → recopy fresh.
                try fm.removeItem(at: destURL)
            }
        }

        var hasher = SHA256()
        var offset: Int64 = 0
        setBytesCopied(index, 0)

        let srcHandle = try FileHandle(forReadingFrom: srcURL)
        defer { try? srcHandle.close() }

        // Verify any partial as a clean prefix of the source, feeding the hasher
        // as we go, so the copy continues instead of restarting. Mismatch → start over.
        if fm.fileExists(atPath: partURL.path) {
            offset = try verifyPrefix(
                part: partURL, srcHandle: srcHandle, hasher: &hasher, fileIndex: index)
            if offset == 0 {
                hasher = SHA256()
                try? fm.removeItem(at: partURL)
                try srcHandle.seek(toOffset: 0)
            }
        }

        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let destHandle = try FileHandle(forWritingTo: partURL)
        defer { try? destHandle.close() }
        try destHandle.truncate(atOffset: UInt64(offset))
        try destHandle.seek(toOffset: UInt64(offset))

        while true {
            try Task.checkCancellation()
            guard let chunk = try srcHandle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            try destHandle.write(contentsOf: chunk)
            offset += Int64(chunk.count)
            setBytesCopied(index, offset)
            recordSpeed(delta: Int64(chunk.count))
            emit()
        }
        try destHandle.close()

        // Preserve the source's modification time, then reveal the finished file.
        try? fm.setAttributes(
            [.modificationDate: record.modificationDate], ofItemAtPath: partURL.path)
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        try fm.moveItem(at: partURL, to: destURL)

        job.files[index].checksum = FileHasher.hex(hasher.finalize())
        job.files[index].status = .copied
        job.doneFiles += 1

        if job.verifyAfterCopy {
            job.currentFile = "Verifying: \(record.relativePath)"
            emit(force: true)
            let destHash = try FileHasher.sha256(of: destURL)
            if destHash == job.files[index].checksum {
                job.files[index].status = .verified
                job.verifiedFiles += 1
            } else {
                job.files[index].status = .failed
                job.files[index].error = "Verification failed: destination checksum differs from source."
                job.doneFiles -= 1
                job.failedFiles += 1
                setBytesCopied(index, 0)
                try? fm.removeItem(at: destURL)
            }
        }
        emit(force: true)
    }

    /// Byte-compare an existing partial against the source while feeding the
    /// hasher. Returns the number of verified prefix bytes (0 = unusable partial).
    private func verifyPrefix(
        part: URL, srcHandle: FileHandle, hasher: inout SHA256, fileIndex: Int
    ) throws -> Int64 {
        let partHandle = try FileHandle(forReadingFrom: part)
        defer { try? partHandle.close() }
        try srcHandle.seek(toOffset: 0)

        job.currentFile = "Resuming: \(job.files[fileIndex].relativePath)"
        emit(force: true)

        var verified: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let partChunk = try partHandle.read(upToCount: Self.chunkSize),
                  !partChunk.isEmpty else { break }
            guard let srcChunk = try srcHandle.read(upToCount: partChunk.count),
                  srcChunk == partChunk else {
                return 0
            }
            hasher.update(data: partChunk)
            verified += Int64(partChunk.count)
            setBytesCopied(fileIndex, verified)
            emit()
        }
        // Leave srcHandle positioned exactly at the end of the verified prefix.
        try srcHandle.seek(toOffset: UInt64(verified))
        return verified
    }

    // MARK: Bookkeeping

    private func setBytesCopied(_ index: Int, _ value: Int64) {
        job.doneBytes += value - job.files[index].bytesCopied
        job.files[index].bytesCopied = value
    }

    /// Rebuild counters from the manifest so drift never accumulates across runs.
    private func recomputeCounters() {
        var doneFiles = 0, skipped = 0, verified = 0, failed = 0
        var doneBytes: Int64 = 0
        for f in job.files {
            switch f.status {
            case .copied, .verified, .skipped:
                doneFiles += 1
                doneBytes += f.size
                if f.status == .skipped { skipped += 1 }
                if f.status == .verified { verified += 1 }
            case .failed:
                failed += 1
            case .pending, .copying:
                doneBytes += f.bytesCopied
            }
        }
        job.doneFiles = doneFiles
        job.doneBytes = doneBytes
        job.skippedFiles = skipped
        job.verifiedFiles = verified
        job.failedFiles = failed
    }

    private func recordSpeed(delta: Int64) {
        let now = Date()
        speedSamples.append((now, delta))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 5 }
        let window = max(now.timeIntervalSince(speedSamples.first?.time ?? now), 0.5)
        job.bytesPerSecond = Double(speedSamples.reduce(0) { $0 + $1.bytes }) / window
    }

    private func emit(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.25 else { return }
        lastEmit = now
        onUpdate(job)
    }

    private func finishStopped() {
        job.currentFile = nil
        job.bytesPerSecond = 0
        switch stopIntent {
        case .cancel:
            job.status = .cancelled
            job.completedAt = Date()
        case .waitForVolume:
            job.status = .waitingForVolume
        case .pause, .none:
            job.status = .paused
        }
        stopIntent = nil
        emit(force: true)
    }

    private func finishWaiting(_ message: String) {
        job.currentFile = nil
        job.bytesPerSecond = 0
        job.status = .waitingForVolume
        job.statusMessage = message
        emit(force: true)
    }

    private func volumeVanished(srcRoot: URL, destRoot: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: srcRoot.path) || !fm.fileExists(atPath: destRoot.path)
    }
}
