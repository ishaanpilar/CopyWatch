import XCTest
@testable import CopyWatch

final class ManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyWatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func records(_ count: Int) -> [FileRecord] {
        (0..<count).map {
            FileRecord(relativePath: "dir/file\($0).bin", size: 10,
                       modificationDate: Date(timeIntervalSinceReferenceDate: Double($0)))
        }
    }

    func testReplaceBatchAndCounters() throws {
        let manifests = ManifestStore(directory: root)
        let id = UUID()
        try manifests.replace(id, records: records(5))

        var done = records(5)[1]
        done.status = .verified
        done.bytesCopied = 10
        done.checksum = "abc"
        var failed = records(5)[3]
        failed.applyFailure(.init(title: "t", fix: "f", icon: "i"))
        manifests.apply(id, changes: [.init(index: 1, record: done), .init(index: 3, record: failed)])

        let loaded = try XCTUnwrap(manifests.load(id))
        XCTAssertEqual(loaded.map(\.relativePath), records(5).map(\.relativePath))
        XCTAssertEqual(loaded[1], done)
        XCTAssertEqual(loaded[0].modificationDate, records(5)[0].modificationDate)
        XCTAssertEqual(manifests.page(id, status: .failed, limit: 10).count, 1)
        XCTAssertEqual(manifests.firstDiagnosedFailure(id)?.errorFix, "f")

        let counters = manifests.counters(id)
        XCTAssertEqual(counters.doneFiles, 1)
        XCTAssertEqual(counters.doneBytes, 10)
        XCTAssertEqual(counters.verifiedFiles, 1)
        XCTAssertEqual(counters.failedFiles, 1)

        manifests.reset(id, failedOnly: true)
        XCTAssertEqual(manifests.count(id, status: .failed), 0)
        XCTAssertEqual(manifests.count(id, status: .verified), 1)
        manifests.reset(id, failedOnly: false)
        XCTAssertEqual(manifests.count(id, status: .pending), 5)

        manifests.delete(id)
        XCTAssertNil(manifests.load(id))
    }

    func testApplyCreatesManifestForDeviceJobs() throws {
        let manifests = ManifestStore(directory: root)
        let id = UUID()
        XCTAssertNil(manifests.load(id))
        manifests.apply(id, changes: [.init(index: 0, record: records(1)[0])])
        XCTAssertEqual(manifests.load(id)?.count, 1)
    }

    func testLegacyJobFileMigratesAndHeaderStaysSmall() throws {
        var job = makeJob(source: root.path, dest: root.path)
        job.files = records(50)
        job.totalFiles = 50
        let store = JobStore(root: root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("jobs/\(job.id.uuidString).json")
        try encoder.encode(job).write(to: url)

        let loaded = try XCTUnwrap(store.loadJobs().first)
        XCTAssertTrue(loaded.files.isEmpty)
        XCTAssertEqual(store.manifests.load(job.id)?.count, 50)

        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((onDisk?["files"] as? [Any])?.count, 0)
        XCTAssertEqual(store.hydrated(loaded)?.files.count, 50)
    }

    func testHydratedRefusesMissingManifest() {
        var job = makeJob(source: root.path, dest: root.path)
        job.totalFiles = 3
        XCTAssertNil(JobStore(root: root).hydrated(job))
    }

    func testEngineStreamsRowsAndKeepsSnapshotsLight() throws {
        let source = root.appendingPathComponent("src")
        for i in 0..<200 {
            let dir = source.appendingPathComponent("d\(i % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("file \(i)".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
        }
        let destParent = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)
        let dest = destParent.appendingPathComponent("src")

        let store = JobStore(root: root.appendingPathComponent("store"))
        var job = makeJob(source: source.path, dest: dest.path)
        let scanned = try Scanner.scan(root: source)
        try store.manifests.replace(job.id, records: scanned)
        job.totalFiles = scanned.count
        job.totalBytes = scanned.reduce(0) { $0 + $1.size }
        job.status = .ready

        let id = job.id
        let manifests = store.manifests
        let finished = expectation(description: "job finished")
        let lock = NSLock()
        var sawManifestInSnapshot = false
        let engine = JobEngine(
            job: job,
            loadManifest: { manifests.load(id) },
            onFilesChanged: { manifests.apply(id, changes: $0) }
        ) { snapshot in
            lock.lock()
            if !snapshot.files.isEmpty { sawManifestInSnapshot = true }
            lock.unlock()
            if snapshot.status == .completed || snapshot.status == .completedWithErrors {
                finished.fulfill()
            }
        }
        engine.start()
        wait(for: [finished], timeout: 60)

        XCTAssertFalse(sawManifestInSnapshot)
        XCTAssertEqual(manifests.count(id, status: .verified), 200)
        XCTAssertEqual(manifests.counters(id).doneFiles, 200)
        XCTAssertNotNil(manifests.load(id)?.first?.checksum)
    }

    private func tree(_ count: Int, name: String) throws -> URL {
        let source = root.appendingPathComponent(name)
        for i in 0..<count {
            let dir = source.appendingPathComponent("d\(i % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("file \(i)".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
        }
        return source
    }

    private func prepare(_ source: URL, store: JobStore) throws -> CopyJob {
        let parent = root.appendingPathComponent("dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var job = makeJob(source: source.path, dest: parent.appendingPathComponent("out").path)
        let scanned = try Scanner.scan(root: source)
        try store.manifests.replace(job.id, records: scanned)
        job.totalFiles = scanned.count
        job.totalBytes = scanned.reduce(0) { $0 + $1.size }
        job.status = .ready
        return job
    }

    /// Runs `job` until it stops; `pauseAfter` pauses at the first snapshot
    /// showing that many finished files.
    private func run(
        _ job: CopyJob, store: JobStore, workers: Int, pauseAfter: Int? = nil
    ) -> CopyJob {
        let manifests = store.manifests
        let id = job.id
        let stopped = expectation(description: "stopped")
        stopped.assertForOverFulfill = false
        let lock = NSLock()
        var last = job
        var engine: JobEngine?
        engine = JobEngine(
            job: job, loadManifest: { manifests.load(id) },
            onFilesChanged: { manifests.apply(id, changes: $0) }, fileWorkers: workers
        ) { snapshot in
            lock.lock(); last = snapshot; let current = engine; lock.unlock()
            if let pauseAfter, snapshot.status == .running, snapshot.doneFiles >= pauseAfter {
                current?.pause()
            }
            switch snapshot.status {
            case .completed, .completedWithErrors, .paused, .interrupted, .waitingForVolume:
                stopped.fulfill()
            default: break
            }
        }
        engine?.start()
        wait(for: [stopped], timeout: 120)
        return last
    }

    func testParallelAndSerialProduceTheSameManifest() throws {
        let source = try tree(150, name: "src")
        let big = source.appendingPathComponent("big.bin")
        try Data(count: Int(JobEngine.smallFileLimit) + 1).write(to: big)

        let store = JobStore(root: root.appendingPathComponent("store"))
        let parallel = try prepare(source, store: store)
        let serial = try prepare(source, store: store)
        XCTAssertEqual(run(parallel, store: store, workers: 8).status, .completed)
        XCTAssertEqual(run(serial, store: store, workers: 1).status, .completed)

        let a = try XCTUnwrap(store.manifests.load(parallel.id))
        let b = try XCTUnwrap(store.manifests.load(serial.id))
        XCTAssertEqual(a.map(\.status), Array(repeating: .verified, count: 151))
        XCTAssertEqual(a.map(\.checksum), b.map(\.checksum))
        XCTAssertEqual(a.map(\.bytesCopied), a.map(\.size))

        let fm = FileManager.default
        for record in a {
            let copy = URL(fileURLWithPath: parallel.destPath).appendingPathComponent(record.relativePath)
            let original = source.appendingPathComponent(record.relativePath)
            XCTAssertTrue(fm.contentsEqual(atPath: copy.path, andPath: original.path), record.relativePath)
            let mtime = try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
            XCTAssertEqual(mtime, record.modificationDate)
        }
    }

    func testPauseThenResumeFinishesEveryFile() throws {
        let source = try tree(6000, name: "src")
        let store = JobStore(root: root.appendingPathComponent("store"))
        let job = try prepare(source, store: store)

        let paused = run(job, store: store, workers: 8, pauseAfter: 50)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(store.manifests.counters(job.id).failedFiles, 0)
        // Nothing the manifest calls copied may be left unverified.
        XCTAssertEqual(store.manifests.count(job.id, status: .copied), 0)

        var resumed = paused
        resumed.status = .interrupted
        let finished = run(resumed, store: store, workers: 8)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.doneFiles, 6000)
        XCTAssertEqual(store.manifests.counters(job.id).doneFiles, 6000)
        XCTAssertEqual(store.manifests.count(job.id, status: .pending), 0)
    }

    private func makeJob(source: String, dest: String) -> CopyJob {
        CopyJob(id: UUID(), name: "test", sourceVolume: .forPath(source),
                destVolume: .forPath(dest), sourcePath: source, destPath: dest)
    }
}
