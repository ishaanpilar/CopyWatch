import Foundation

/// JSON-on-disk persistence: one file per job / comparison under Application
/// Support. A job's manifest is kept apart, in `manifests`.
final class JobStore: @unchecked Sendable {
    let root: URL
    let manifests: ManifestStore
    private let queue = DispatchQueue(label: "copywatch.store")
    private var lastSave: [UUID: Date] = [:]
    private var lastSavedStatus: [UUID: JobStatus] = [:]

    init(root: URL? = nil) {
        let base = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyWatch", isDirectory: true)
        self.root = base
        manifests = ManifestStore(directory: base.appendingPathComponent("manifests"))
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("jobs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("compares"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    private func jobURL(_ id: UUID) -> URL {
        root.appendingPathComponent("jobs/\(id.uuidString).json")
    }
    private func compareURL(_ id: UUID) -> URL {
        root.appendingPathComponent("compares/\(id.uuidString).json")
    }

    // MARK: Jobs

    /// Persist a job's header (never its manifest). Progress-only updates are
    /// throttled to one per `progressSaveInterval` and queued
    /// asynchronously; `force` (status changes, completion) writes
    /// synchronously so the call cannot return — and a process cannot exit —
    /// before the final state is actually on disk. Without this, a job that
    /// finishes right before the app or a headless run quits can leave a
    /// stale, mid-copy snapshot as its permanent history record.
    func save(_ job: CopyJob, force: Bool = false) {
        var job = job
        job.files = []
        if force {
            queue.sync { [self] in
                lastSave[job.id] = Date()
                lastSavedStatus[job.id] = job.status
                write(job, to: jobURL(job.id))
            }
            return
        }
        queue.async { [self] in
            let statusChanged = lastSavedStatus[job.id] != job.status
            if !statusChanged,
               let last = lastSave[job.id], Date().timeIntervalSince(last) < Self.progressSaveInterval {
                return
            }
            lastSave[job.id] = Date()
            lastSavedStatus[job.id] = job.status
            write(job, to: jobURL(job.id))
        }
    }

    /// Counters are rebuilt from the manifest on resume, so this only limits
    /// how stale a crashed job's displayed progress can be.
    private static let progressSaveInterval: TimeInterval = 5

    /// Load every job header. Job files from before `ManifestStore` still
    /// embed their manifest: it moves to the database once, and a job whose
    /// manifest cannot be moved is skipped with its file left untouched.
    func loadJobs() -> [CopyJob] {
        let jobs: [CopyJob] = load(from: root.appendingPathComponent("jobs"))
        return jobs.compactMap { job in
            guard !job.files.isEmpty else { return job }
            guard (try? manifests.replace(job.id, records: job.files)) != nil else { return nil }
            var header = job
            header.files = []
            save(header, force: true)
            return header
        }
    }

    /// `job` with its manifest loaded, or nil if a job that has files can't
    /// read them — callers must not mistake that for an empty manifest.
    func hydrated(_ job: CopyJob) -> CopyJob? {
        guard job.files.isEmpty else { return job }
        var full = job
        full.files = manifests.load(job.id) ?? []
        return full.files.isEmpty && job.totalFiles > 0 ? nil : full
    }

    func delete(_ job: CopyJob) {
        manifests.delete(job.id)
        queue.async { [self] in try? FileManager.default.removeItem(at: jobURL(job.id)) }
    }

    // MARK: Comparisons

    /// Comparisons save once, at completion — always synchronous for the same
    /// reason as a forced job save.
    func save(_ record: ComparisonRecord) {
        queue.sync { [self] in write(record, to: compareURL(record.id)) }
    }

    func loadComparisons() -> [ComparisonRecord] {
        load(from: root.appendingPathComponent("compares"))
    }

    func delete(_ record: ComparisonRecord) {
        queue.async { [self] in try? FileManager.default.removeItem(at: compareURL(record.id)) }
    }

    // MARK: Projects — small files, saved synchronously on every change.

    private func projectURL(_ id: UUID) -> URL {
        root.appendingPathComponent("projects/\(id.uuidString).json")
    }

    func save(_ project: Project) {
        queue.sync { [self] in write(project, to: projectURL(project.id)) }
    }

    func loadProjects() -> [Project] {
        load(from: root.appendingPathComponent("projects"))
    }

    func delete(_ project: Project) {
        queue.async { [self] in try? FileManager.default.removeItem(at: projectURL(project.id)) }
    }

    // MARK: Destination presets — small list, always written whole and in full.

    private var destinationsURL: URL { root.appendingPathComponent("destinations.json") }

    func saveDestinations(_ presets: [DestinationPreset]) {
        queue.sync { [self] in write(presets, to: destinationsURL) }
    }

    func loadDestinations() -> [DestinationPreset] {
        guard let data = try? Data(contentsOf: destinationsURL) else { return [] }
        return (try? JSONDecoder().decode([DestinationPreset].self, from: data)) ?? []
    }

    // MARK: Benchmarks

    private var benchmarksURL: URL { root.appendingPathComponent("benchmarks.json") }

    func saveBenchmarks(_ results: [BenchmarkResult]) {
        queue.sync { [self] in write(results, to: benchmarksURL) }
    }

    func loadBenchmarks() -> [BenchmarkResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: benchmarksURL) else { return [] }
        return (try? decoder.decode([BenchmarkResult].self, from: data)) ?? []
    }

    // MARK: Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load<T: Decodable>(from dir: URL) -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(T.self, from: data)
            }
    }
}
