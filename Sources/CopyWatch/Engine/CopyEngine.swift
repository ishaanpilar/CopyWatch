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
    private var lastHistorySample = Date.distantPast

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
        let srcRoot = URL(fileURLWithPath: job.sourcePath)

        // Resolve the primary destination and any extras, refreshing their paths.
        let primaryParent = (job.destPath as NSString).deletingLastPathComponent
        guard let primaryResolved = job.destVolume.resolve(primaryParent) else {
            return finishWaiting("Destination drive “\(job.destVolume.name)” is not connected.")
        }
        job.destPath = (primaryResolved as NSString)
            .appendingPathComponent((job.destPath as NSString).lastPathComponent)
        var destRoots = [URL(fileURLWithPath: job.destPath)]

        for i in job.extraDestinations.indices {
            let dest = job.extraDestinations[i]
            let parent = (dest.path as NSString).deletingLastPathComponent
            guard let resolvedParent = dest.volume.resolve(parent) else {
                return finishWaiting("Destination drive “\(dest.volume.name)” is not connected.")
            }
            let resolved = (resolvedParent as NSString)
                .appendingPathComponent((dest.path as NSString).lastPathComponent)
            job.extraDestinations[i].path = resolved
            destRoots.append(URL(fileURLWithPath: resolved))
        }

        for root in destRoots {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return finishWaiting(CopyDiagnosis.diagnose(error, path: root.path).fix)
            }
        }

        // A file interrupted mid-copy resumes from its partial data.
        for i in job.files.indices where job.files[i].status == .copying {
            job.files[i].status = .pending
        }
        recomputeCounters()

        // Recognize everything already complete at EVERY destination (a previous
        // run, or a dead Finder copy). Smart duplicate detection: hash the
        // ambiguous size-match/date-mismatch case rather than recopy blindly.
        job.status = .running
        job.statusMessage = destRoots.count > 1
            ? "Checking what's already at \(destRoots.count) destinations…"
            : "Checking what's already at the destination…"
        emit(force: true)
        Reconciler.reconcile(job: &job, destRoots: destRoots, sourceRoot: srcRoot, deep: true)
        job.statusMessage = nil
        speedSamples.removeAll()
        job.speedHistory.removeAll()   // this run's own throughput profile
        emit(force: true)

        for i in job.files.indices where !job.files[i].isDone && job.files[i].status != .failed {
            do {
                try Task.checkCancellation()
                if destRoots.count == 1 {
                    try copyOneFile(at: i, srcRoot: srcRoot, destRoot: destRoots[0])
                } else {
                    try copyOneFileMulti(at: i, srcRoot: srcRoot, destRoots: destRoots)
                }
            } catch is CancellationError {
                return finishStopped()
            } catch {
                if volumeVanished(srcRoot: srcRoot, destRoots: destRoots) {
                    job.files[i].status = .pending
                    return finishWaiting(CopyDiagnosis.diagnose(error, volumeVanished: true).fix)
                }
                job.files[i].applyFailure(CopyDiagnosis.diagnose(error, path: job.files[i].relativePath))
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

        // Pipelined: a reader thread reads+hashes while this thread writes, so
        // read and write overlap (a big win when source and destination are on
        // different drives — the camera-card-to-backup case).
        let sourceHash = try streamTail(
            source: srcHandle, seededHasher: hasher,
            writeHandles: [destHandle], fileIndex: index, startOffset: offset)
        try destHandle.close()

        // Preserve the source's modification time, then reveal the finished file.
        try? fm.setAttributes(
            [.modificationDate: record.modificationDate], ofItemAtPath: partURL.path)
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        try fm.moveItem(at: partURL, to: destURL)

        job.files[index].checksum = sourceHash
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
                job.files[index].applyFailure(Self.verificationFailure())
                job.doneFiles -= 1
                job.failedFiles += 1
                setBytesCopied(index, 0)
                try? fm.removeItem(at: destURL)
            }
        }
        emit(force: true)
    }

    static func verificationFailure(at destination: String? = nil) -> CopyDiagnosis {
        let where_ = destination.map { " at \($0)" } ?? ""
        return .init(
            title: "Verification failed\(where_)",
            fix: "The copy\(where_) didn't match the source — usually a flaky cable, hub, or a failing drive. Resume to re-copy it; if it keeps happening, run a Transfer Benchmark on that drive.",
            icon: "xmark.seal")
    }

    // MARK: One file → many destinations (read source once, write to all, verify each)

    private func copyOneFileMulti(at index: Int, srcRoot: URL, destRoots: [URL]) throws {
        let record = job.files[index]
        let srcURL = srcRoot.appendingPathComponent(record.relativePath)
        let fm = FileManager.default

        // Smart dedup per destination: only write where it isn't already identical.
        let needed = destRoots.filter {
            Reconciler.classifyDeep(record, destRoot: $0, sourceRoot: srcRoot) != .match
        }
        if needed.isEmpty {
            setBytesCopied(index, record.size)
            job.files[index].status = job.verifyAfterCopy ? .verified : .copied
            job.doneFiles += 1
            if job.verifyAfterCopy { job.verifiedFiles += 1 }
            emit(force: true)
            return
        }

        job.files[index].status = .copying
        job.currentFile = "\(record.relativePath) → \(needed.count) drive\(needed.count == 1 ? "" : "s")"
        emit(force: true)

        // Prepare a .cwpart per needed destination, adopting any partial leftover.
        var partURLs: [URL] = []
        for root in needed {
            let destURL = root.appendingPathComponent(record.relativePath)
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partURL = destURL.appendingPathExtension(String(Self.partSuffix.dropFirst()))
            if !fm.fileExists(atPath: partURL.path), fm.fileExists(atPath: destURL.path) {
                let attrs = try fm.attributesOfItem(atPath: destURL.path)
                let destSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if destSize < record.size { try fm.moveItem(at: destURL, to: partURL) }
                else { try fm.removeItem(at: destURL) }
            }
            partURLs.append(partURL)
        }

        // Resume only when every destination shares a matching prefix; otherwise
        // start them all fresh (keeps multi-destination resume correct & simple).
        var resumeOffset: Int64 = 0
        if partURLs.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
            resumeOffset = try commonValidPrefix(srcURL: srcURL, parts: partURLs)
        }
        if resumeOffset == 0 {
            for p in partURLs where fm.fileExists(atPath: p.path) { try fm.removeItem(at: p) }
        }

        var hasher = SHA256()
        let srcHandle = try FileHandle(forReadingFrom: srcURL)
        defer { try? srcHandle.close() }

        var handles: [FileHandle] = []
        for p in partURLs {
            if !fm.fileExists(atPath: p.path) { fm.createFile(atPath: p.path, contents: nil) }
            let h = try FileHandle(forWritingTo: p)
            try h.truncate(atOffset: UInt64(resumeOffset))
            try h.seek(toOffset: UInt64(resumeOffset))
            handles.append(h)
        }
        defer { for h in handles { try? h.close() } }

        // Feed the resumed prefix (already on all parts) into the hasher.
        var offset: Int64 = 0
        setBytesCopied(index, 0)
        if resumeOffset > 0 {
            try srcHandle.seek(toOffset: 0)
            var remaining = resumeOffset
            while remaining > 0 {
                try Task.checkCancellation()
                let want = Int(min(Int64(Self.chunkSize), remaining))
                guard let chunk = try srcHandle.read(upToCount: want), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            offset = resumeOffset
            setBytesCopied(index, offset)
        }

        try srcHandle.seek(toOffset: UInt64(offset))
        // Pipelined read/hash → fan-out write to every destination.
        let sourceHash = try streamTail(
            source: srcHandle, seededHasher: hasher,
            writeHandles: handles, fileIndex: index, startOffset: offset)
        for h in handles { try h.close() }
        job.files[index].checksum = sourceHash

        for (k, root) in needed.enumerated() {
            let destURL = root.appendingPathComponent(record.relativePath)
            let partURL = partURLs[k]
            try? fm.setAttributes(
                [.modificationDate: record.modificationDate], ofItemAtPath: partURL.path)
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.moveItem(at: partURL, to: destURL)

            if job.verifyAfterCopy {
                job.currentFile = "Verifying: \(record.relativePath)"
                emit(force: true)
                let destHash = try FileHasher.sha256(of: destURL)
                if destHash != sourceHash {
                    job.files[index].applyFailure(Self.verificationFailure(at: destName(for: root)))
                    setBytesCopied(index, 0)
                    try? fm.removeItem(at: destURL)
                    job.failedFiles += 1
                    emit(force: true)
                    return
                }
            }
        }

        job.files[index].status = job.verifyAfterCopy ? .verified : .copied
        job.doneFiles += 1
        if job.verifyAfterCopy { job.verifiedFiles += 1 }
        emit(force: true)
    }

    /// Longest byte prefix that matches the source in EVERY part file. Reads the
    /// source and each part once, in lockstep.
    private func commonValidPrefix(srcURL: URL, parts: [URL]) throws -> Int64 {
        let src = try FileHandle(forReadingFrom: srcURL)
        defer { try? src.close() }
        let partHandles = try parts.map { try FileHandle(forReadingFrom: $0) }
        defer { for h in partHandles { try? h.close() } }
        var valid: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let sChunk = try src.read(upToCount: Self.chunkSize), !sChunk.isEmpty else { break }
            for h in partHandles {
                guard let pChunk = try h.read(upToCount: sChunk.count), pChunk == sChunk else {
                    return valid
                }
            }
            valid += Int64(sChunk.count)
        }
        return valid
    }

    private func destName(for root: URL) -> String {
        if let d = job.allDestinations.first(where: { $0.path == root.path }) { return d.volume.name }
        return (root.path as NSString).lastPathComponent
    }

    /// Pipelined tail copy: a reader thread reads from `source` and hashes,
    /// while this (writer) thread writes each chunk to every `writeHandles`.
    /// Read and write overlap through a small bounded buffer. Returns the final
    /// SHA-256 of the whole file (the passed hasher is pre-seeded with any
    /// already-verified prefix). Progress and speed are updated on this thread,
    /// so job state stays single-threaded.
    private func streamTail(
        source: FileHandle, seededHasher: SHA256,
        writeHandles: [FileHandle], fileIndex: Int, startOffset: Int64
    ) throws -> String {
        let pipe = ChunkPipe(capacity: 4)
        let done = DispatchSemaphore(value: 0)
        final class Result: @unchecked Sendable { var hash = ""; var error: Error? }
        let result = Result()

        let reader = Thread {
            var hasher = seededHasher
            do {
                while true {
                    guard let chunk = try source.read(upToCount: Self.chunkSize),
                          !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    if !pipe.push(chunk) { break }   // writer aborted
                }
                result.hash = FileHasher.hex(hasher.finalize())
            } catch {
                result.error = error
            }
            pipe.finish()
            done.signal()
        }
        reader.stackSize = 1 << 20
        reader.start()

        var offset = startOffset
        var writeError: Error?
        setBytesCopied(fileIndex, offset)
        loop: while true {
            do { try Task.checkCancellation() } catch { writeError = error; break loop }
            guard let chunk = pipe.pop() else { break }   // drained + reader finished
            do {
                for h in writeHandles { try h.write(contentsOf: chunk) }
            } catch {
                writeError = error
                break loop
            }
            offset += Int64(chunk.count)
            setBytesCopied(fileIndex, offset)
            recordSpeed(delta: Int64(chunk.count))
            emit()
        }
        if writeError != nil { pipe.abort() }
        done.wait()   // reader has released the source handle
        if let e = writeError { throw e }
        if let e = result.error { throw e }
        return result.hash
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

        // Record the throughput profile ~1×/sec for the speed graph.
        if now.timeIntervalSince(lastHistorySample) >= 1.0 {
            lastHistorySample = now
            job.speedHistory.append(job.bytesPerSecond / 1_000_000)  // MB/s
            if job.speedHistory.count > 240 { job.speedHistory.removeFirst() }
        }
    }

    private func emit(force: Bool = false) {
        // 2 Hz keeps progress lively without re-rendering large manifests
        // (sidebar + file table) faster than the eye needs.
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.5 else { return }
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

    private func volumeVanished(srcRoot: URL, destRoots: [URL]) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: srcRoot.path) { return true }
        return destRoots.contains { !fm.fileExists(atPath: $0.path) }
    }
}

/// A tiny bounded blocking queue between the reader thread and the writer,
/// giving read/write overlap with a fixed memory ceiling (capacity × chunk).
private final class ChunkPipe: @unchecked Sendable {
    private let capacity: Int
    private var buffer: [Data] = []
    private var closed = false
    private var aborted = false
    private let cond = NSCondition()

    init(capacity: Int) { self.capacity = capacity }

    /// Producer: blocks while full. Returns false if the consumer aborted.
    func push(_ data: Data) -> Bool {
        cond.lock(); defer { cond.unlock() }
        while buffer.count >= capacity && !aborted { cond.wait() }
        if aborted { return false }
        buffer.append(data)
        cond.signal()
        return true
    }

    /// Consumer: blocks until a chunk is available; nil once drained and closed.
    func pop() -> Data? {
        cond.lock(); defer { cond.unlock() }
        while buffer.isEmpty && !closed && !aborted { cond.wait() }
        if buffer.isEmpty { return nil }
        let d = buffer.removeFirst()
        cond.signal()
        return d
    }

    func finish() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
    func abort() { cond.lock(); aborted = true; cond.broadcast(); cond.unlock() }
}
