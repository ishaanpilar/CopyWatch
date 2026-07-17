import Foundation

/// Runs one job: chunked copy with a streaming checksum, per-file verify,
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
        TransferLog.shared.begin(label: job.name)
        TransferLog.shared.log("config", [
            "totalFiles": job.totalFiles, "totalBytes": job.totalBytes,
            "verify": job.verifyAfterCopy, "destinations": job.allDestinations.count,
            "chunkBytes": Self.chunkSize])
        defer { TransferLog.shared.end() }

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
                let diag = CopyDiagnosis.diagnose(error, path: job.files[i].relativePath)
                if diag.haltsTransfer {
                    // The destination is full or read-only — every remaining file
                    // would fail too. Stop resumably and keep this file pending
                    // (its partial .cwpart is preserved) so Try Again continues
                    // exactly where it left off.
                    job.files[i].status = .pending
                    return finishInterrupted(diag)
                }
                job.files[i].applyFailure(diag)
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

        var hasher = job.checksumAlgorithm.makeHasher()
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
                hasher = job.checksumAlgorithm.makeHasher()
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
        // Flush to the device before verifying, so the read-back can't be served
        // from the write cache (a masked corruption). Only needed when verifying.
        if job.verifyAfterCopy { _ = fcntl(destHandle.fileDescriptor, F_FULLFSYNC, 0) }
        try destHandle.close()

        // Preserve the source's modification time, then reveal the finished file.
        try? fm.setAttributes(
            [.modificationDate: record.modificationDate], ofItemAtPath: partURL.path)
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        try fm.moveItem(at: partURL, to: destURL)
        // Carry over permissions, Finder tags/xattrs, ACLs, and creation date.
        Self.copyMetadata(from: srcURL, to: destURL)

        job.files[index].checksum = sourceHash
        job.files[index].status = .copied
        job.doneFiles += 1

        if job.verifyAfterCopy {
            job.currentFile = "Verifying: \(record.relativePath)"
            emit(force: true)
            let vT = DispatchTime.now().uptimeNanoseconds
            let destHash = try FileHasher.hash(
                of: destURL, algorithm: job.checksumAlgorithm, bypassCache: true)
            if TransferLog.shared.active {
                let sec = Double(DispatchTime.now().uptimeNanoseconds &- vT) / 1e9
                TransferLog.shared.log("verify", [
                    "file": index, "bytes": record.size, "seconds": round3(sec),
                    "MBps": sec > 0 ? round(Double(record.size) / 1e6 / sec) : 0])
            }
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

        var hasher = job.checksumAlgorithm.makeHasher()
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
                let n: Int = try autoreleasepool {
                    let want = Int(min(Int64(Self.chunkSize), remaining))
                    guard let chunk = try srcHandle.read(upToCount: want), !chunk.isEmpty else { return 0 }
                    hasher.update(chunk)
                    return chunk.count
                }
                if n == 0 { break }
                remaining -= Int64(n)
            }
            offset = resumeOffset
            setBytesCopied(index, offset)
        }

        try srcHandle.seek(toOffset: UInt64(offset))
        // Pipelined read/hash → fan-out write to every destination.
        let sourceHash = try streamTail(
            source: srcHandle, seededHasher: hasher,
            writeHandles: handles, fileIndex: index, startOffset: offset)
        if job.verifyAfterCopy { for h in handles { _ = fcntl(h.fileDescriptor, F_FULLFSYNC, 0) } }
        for h in handles { try h.close() }
        job.files[index].checksum = sourceHash

        for (k, root) in needed.enumerated() {
            let destURL = root.appendingPathComponent(record.relativePath)
            let partURL = partURLs[k]
            try? fm.setAttributes(
                [.modificationDate: record.modificationDate], ofItemAtPath: partURL.path)
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.moveItem(at: partURL, to: destURL)
            Self.copyMetadata(from: srcURL, to: destURL)

            if job.verifyAfterCopy {
                job.currentFile = "Verifying: \(record.relativePath)"
                emit(force: true)
                let destHash = try FileHasher.hash(
                    of: destURL, algorithm: job.checksumAlgorithm, bypassCache: true)
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
        enum Step { case stop, more(Int64) }
        while true {
            try Task.checkCancellation()
            let step: Step = try autoreleasepool {
                guard let sChunk = try src.read(upToCount: Self.chunkSize), !sChunk.isEmpty else { return .stop }
                for h in partHandles {
                    guard let pChunk = try h.read(upToCount: sChunk.count), pChunk == sChunk else {
                        return .stop
                    }
                }
                return .more(Int64(sChunk.count))
            }
            switch step {
            case .stop: return valid
            case .more(let c): valid += c
            }
        }
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
        source: FileHandle, seededHasher: any StreamingHasher,
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
                    // autoreleasepool per chunk: the pipe retains what it needs,
                    // so only the in-flight chunks stay resident (not the whole
                    // file's worth of autoreleased reads).
                    let more = try autoreleasepool { () -> Bool in
                        guard let chunk = try source.read(upToCount: Self.chunkSize),
                              !chunk.isEmpty else { return false }
                        hasher.update(chunk)
                        return pipe.push(chunk)   // false = EOF handled below or writer aborted
                    }
                    if !more { break }
                }
                result.hash = hasher.finalizedHex()
            } catch {
                result.error = error
            }
            pipe.finish()
            done.signal()
        }
        reader.stackSize = 1 << 20
        reader.qualityOfService = .userInitiated   // match the copy task; avoid App Nap throttling
        reader.start()

        var offset = startOffset
        var writeError: Error?
        setBytesCopied(fileIndex, offset)

        // With more than one destination, fan the per-chunk writes out across a
        // concurrent queue so a chunk costs the SLOWEST drive's write time, not
        // the sum — two backup drives finish in roughly the time of one. Single
        // destination keeps the plain inline write (zero overhead).
        let fanoutQueue = writeHandles.count > 1
            ? DispatchQueue(label: "copywatch.fanout", attributes: .concurrent)
            : nil

        // Diagnostics: measure real (unsmoothed) throughput and where the loop
        // spends its time — waiting on pop() (read-bound), inside write()
        // (write-bound), or in emit()/bookkeeping (UI overhead).
        let diag = TransferLog.shared.active
        let loopStart = DispatchTime.now().uptimeNanoseconds
        var sampleAtNs = loopStart
        var bytesAtSample = offset
        var writeNs: UInt64 = 0, popNs: UInt64 = 0, emitNs: UInt64 = 0

        loop: while true {
            do { try Task.checkCancellation() } catch { writeError = error; break loop }
            let popT = diag ? DispatchTime.now().uptimeNanoseconds : 0
            guard let chunk = pipe.pop() else { break }   // drained + reader finished
            if diag { popNs &+= DispatchTime.now().uptimeNanoseconds &- popT }
            do {
                let wT = diag ? DispatchTime.now().uptimeNanoseconds : 0
                if let fanoutQueue {
                    // Each handle is a distinct file, so concurrent writes don't
                    // share state; wait for all before advancing to the next chunk.
                    let group = DispatchGroup()
                    let errBox = ErrorBox()
                    for h in writeHandles {
                        fanoutQueue.async(group: group) {
                            do { try h.write(contentsOf: chunk) } catch { errBox.set(error) }
                        }
                    }
                    group.wait()
                    if let e = errBox.error { throw e }
                } else {
                    try writeHandles[0].write(contentsOf: chunk)
                }
                if diag { writeNs &+= DispatchTime.now().uptimeNanoseconds &- wT }
            } catch {
                writeError = error
                break loop
            }
            offset += Int64(chunk.count)
            setBytesCopied(fileIndex, offset)
            recordSpeed(delta: Int64(chunk.count))
            let eT = diag ? DispatchTime.now().uptimeNanoseconds : 0
            emit()
            if diag {
                emitNs &+= DispatchTime.now().uptimeNanoseconds &- eT
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if nowNs &- sampleAtNs >= 250_000_000 {   // ~4×/sec
                    let dt = Double(nowNs &- sampleAtNs) / 1e9
                    let instMBps = Double(offset - bytesAtSample) / 1e6 / dt
                    TransferLog.shared.log("sample", [
                        "file": fileIndex,
                        "instMBps": round(instMBps),
                        "avgMBps": round(job.bytesPerSecond / 1e6),
                        "pipeDepth": (writeHandles.count),   // context only
                        "readBlockedMs": round(Double(pipe.writeBlockedNs) / 1e6),
                        "writeBlockedMs": round(Double(pipe.readBlockedNs) / 1e6),
                    ])
                    sampleAtNs = nowNs
                    bytesAtSample = offset
                }
            }
        }
        if writeError != nil { pipe.abort() }
        done.wait()   // reader has released the source handle

        if diag {
            let totalNs = DispatchTime.now().uptimeNanoseconds &- loopStart
            let sec = Double(totalNs) / 1e9
            let bytes = offset - startOffset
            TransferLog.shared.log("stream_end", [
                "file": fileIndex,
                "bytes": bytes,
                "seconds": round3(sec),
                "MBps": sec > 0 ? round(Double(bytes) / 1e6 / sec) : 0,
                // read-bound = consumer waited on empty pipe; write-bound =
                // producer waited on full pipe.
                "readBoundMs": round(Double(pipe.writeBlockedNs) / 1e6),
                "writeBoundMs": round(Double(pipe.readBlockedNs) / 1e6),
                "writeCallMs": round(Double(writeNs) / 1e6),
                "popCallMs": round(Double(popNs) / 1e6),
                "emitMs": round(Double(emitNs) / 1e6),
                "maxPipeDepth": pipe.maxDepth,
            ])
        }
        if let e = writeError { throw e }
        if let e = result.error { throw e }
        return result.hash
    }

    private func round(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// Best-effort copy of a file's metadata (POSIX mode, ACLs, extended
    /// attributes incl. Finder tags, and creation date) from source to the
    /// finished destination. Data is already written; `COPYFILE_METADATA`
    /// touches everything but the bytes. Failures (e.g. chown across users)
    /// are ignored — the copy itself is already verified.
    static func copyMetadata(from src: URL, to dest: URL) {
        _ = src.withUnsafeFileSystemRepresentation { s in
            dest.withUnsafeFileSystemRepresentation { d in
                copyfile(s, d, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        }
        // copyfile doesn't reliably carry the creation date (birthtime) across
        // APFS, so set it explicitly from the source — this is what lets media
        // stay sorted by "date taken" after an offload.
        let fm = FileManager.default
        if let crt = (try? fm.attributesOfItem(atPath: src.path))?[.creationDate] as? Date {
            try? fm.setAttributes([.creationDate: crt], ofItemAtPath: dest.path)
        }
    }

    /// Byte-compare an existing partial against the source while feeding the
    /// hasher. Returns the number of verified prefix bytes (0 = unusable partial).
    private func verifyPrefix(
        part: URL, srcHandle: FileHandle, hasher: inout any StreamingHasher, fileIndex: Int
    ) throws -> Int64 {
        let partHandle = try FileHandle(forReadingFrom: part)
        defer { try? partHandle.close() }
        try srcHandle.seek(toOffset: 0)

        job.currentFile = "Resuming: \(job.files[fileIndex].relativePath)"
        emit(force: true)

        var verified: Int64 = 0
        enum Step { case done, mismatch, more(Int64) }
        loop: while true {
            try Task.checkCancellation()
            let step: Step = try autoreleasepool {
                guard let partChunk = try partHandle.read(upToCount: Self.chunkSize),
                      !partChunk.isEmpty else { return .done }
                guard let srcChunk = try srcHandle.read(upToCount: partChunk.count),
                      srcChunk == partChunk else { return .mismatch }
                hasher.update(partChunk)
                return .more(Int64(partChunk.count))
            }
            switch step {
            case .done: break loop
            case .mismatch: return 0
            case .more(let c):
                verified += c
                setBytesCopied(fileIndex, verified)
                emit()
            }
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

    /// Stop the transfer in a resumable state after a destination-wide problem
    /// (full / read-only). The drive is still connected, so this is distinct
    /// from `waitingForVolume`: the user fixes the cause and Tries Again, or
    /// switches the destination.
    private func finishInterrupted(_ diagnosis: CopyDiagnosis) {
        job.currentFile = nil
        job.bytesPerSecond = 0
        job.status = .interrupted
        job.statusMessage = "\(diagnosis.title). \(diagnosis.fix)"
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

    // Diagnostics (nanoseconds). `readBlockedNs` is time the reader/producer
    // spent stalled because the pipe was full → the WRITE side (disk write) is
    // the bottleneck. `writeBlockedNs` is time the writer/consumer spent stalled
    // because the pipe was empty → the READ side (disk read) is the bottleneck.
    private(set) var readBlockedNs: UInt64 = 0
    private(set) var writeBlockedNs: UInt64 = 0
    private(set) var maxDepth = 0

    init(capacity: Int) { self.capacity = capacity }

    /// Producer: blocks while full. Returns false if the consumer aborted.
    func push(_ data: Data) -> Bool {
        cond.lock(); defer { cond.unlock() }
        if buffer.count >= capacity && !aborted {
            let w = DispatchTime.now().uptimeNanoseconds
            while buffer.count >= capacity && !aborted { cond.wait() }
            readBlockedNs &+= DispatchTime.now().uptimeNanoseconds &- w
        }
        if aborted { return false }
        buffer.append(data)
        if buffer.count > maxDepth { maxDepth = buffer.count }
        cond.signal()
        return true
    }

    /// Consumer: blocks until a chunk is available; nil once drained and closed.
    func pop() -> Data? {
        cond.lock(); defer { cond.unlock() }
        if buffer.isEmpty && !closed && !aborted {
            let w = DispatchTime.now().uptimeNanoseconds
            while buffer.isEmpty && !closed && !aborted { cond.wait() }
            writeBlockedNs &+= DispatchTime.now().uptimeNanoseconds &- w
        }
        if buffer.isEmpty { return nil }
        let d = buffer.removeFirst()
        cond.signal()
        return d
    }

    func finish() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
    func abort() { cond.lock(); aborted = true; cond.broadcast(); cond.unlock() }
}

/// Thread-safe holder for the first error seen across concurrent destination writes.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}
