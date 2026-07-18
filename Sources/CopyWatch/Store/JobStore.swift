import Foundation

/// JSON-on-disk persistence: one file per job / comparison under Application Support.
final class JobStore: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "copywatch.store")
    private var lastSave: [UUID: Date] = [:]
    private var lastSavedStatus: [UUID: JobStatus] = [:]

    init(root: URL? = nil) {
        let base = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyWatch", isDirectory: true)
        self.root = base
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

    /// Persist a job. Progress-only updates are throttled to ~1/sec and queued
    /// asynchronously; `force` (status changes, completion) writes
    /// synchronously so the call cannot return — and a process cannot exit —
    /// before the final state is actually on disk. Without this, a job that
    /// finishes right before the app or a headless run quits can leave a
    /// stale, mid-copy snapshot as its permanent history record.
    func save(_ job: CopyJob, force: Bool = false) {
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
               let last = lastSave[job.id], Date().timeIntervalSince(last) < 1.0 {
                return
            }
            lastSave[job.id] = Date()
            lastSavedStatus[job.id] = job.status
            write(job, to: jobURL(job.id))
        }
    }

    func loadJobs() -> [CopyJob] {
        load(from: root.appendingPathComponent("jobs"))
    }

    func delete(_ job: CopyJob) {
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
