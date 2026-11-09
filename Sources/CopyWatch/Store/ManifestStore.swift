import Foundation
import SQLite3

/// Per-status tallies of a manifest, enough to rebuild a job's running counters.
struct ManifestCounters {
    var doneFiles = 0
    var doneBytes: Int64 = 0
    var skippedFiles = 0
    var verifiedFiles = 0
    var failedFiles = 0
}

/// File manifests in SQLite, one database per job under `manifests/`. The
/// manifest grows with the file count, so it never travels with `CopyJob`
/// snapshots or the job's JSON; finished files are written as single rows.
final class ManifestStore: @unchecked Sendable {
    enum StoreError: Error { case sqlite(String) }

    private let directory: URL
    private let queue = DispatchQueue(label: "copywatch.manifests")
    /// Connections kept open between calls. Only touched on `queue`.
    private var open: [UUID: OpaquePointer] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).sqlite")
    }

    // MARK: Writing

    /// Atomically install `records` as the job's whole manifest. The new
    /// database is built beside the old one, so an interrupted replace leaves
    /// the previous manifest intact and readers are not blocked meanwhile.
    func replace(_ id: UUID, records: [FileRecord]) throws {
        let target = url(id)
        let building = target.appendingPathExtension("building")
        try? FileManager.default.removeItem(at: building)
        do {
            let db = try Self.connect(building)
            defer { sqlite3_close(db) }
            // No journal: the file only becomes the manifest once complete.
            try Self.exec(db, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
            try Self.exec(db, Self.schema)
            try Self.exec(db, "BEGIN")
            try Self.upsert(db, records.enumerated().map { FileChange(index: $0.offset, record: $0.element) })
            try Self.exec(db, "COMMIT")
            try Self.exec(db, Self.statusIndex)
        } catch {
            try? FileManager.default.removeItem(at: building)
            throw error
        }
        try queue.sync {
            closeConnection(id)
            removeSidecars(target)
            guard rename(building.path, target.path) == 0 else {
                throw StoreError.sqlite(String(cString: strerror(errno)))
            }
        }
    }

    /// Write a batch of changed rows in one transaction, creating the manifest
    /// if needed (device jobs learn theirs from the catalog mid-run).
    func apply(_ id: UUID, changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        queue.sync {
            guard let db = connection(id, create: true) else { return }
            do {
                try Self.exec(db, "BEGIN")
                try Self.upsert(db, changes)
                try Self.exec(db, "COMMIT")
            } catch {
                _ = try? Self.exec(db, "ROLLBACK")
            }
        }
    }

    /// Back to pending, keeping what is already done: failed files only, or all.
    func reset(_ id: UUID, failedOnly: Bool) {
        queue.sync {
            guard let db = connection(id) else { return }
            try? Self.exec(db, """
                UPDATE files SET status='pending', bytes_copied=0, checksum=NULL,
                    error=NULL, error_fix=NULL, error_icon=NULL
                \(failedOnly ? "WHERE status='failed'" : "")
                """)
        }
    }

    /// Release a job's connection (checkpoints its write-ahead log).
    func close(_ id: UUID) {
        queue.sync { closeConnection(id) }
    }

    func delete(_ id: UUID) {
        queue.sync {
            closeConnection(id)
            let target = url(id)
            removeSidecars(target)
            try? FileManager.default.removeItem(at: target)
        }
    }

    // MARK: Reading

    /// The whole manifest in order, or nil if it is missing or unreadable.
    func load(_ id: UUID) -> [FileRecord]? {
        records(id, sql: "SELECT \(Self.columns) FROM files ORDER BY seq")
    }

    /// The first `limit` rows, optionally of one status.
    func page(_ id: UUID, status: FileStatus?, limit: Int) -> [FileRecord] {
        let filter = status.map { "WHERE status='\($0.rawValue)'" } ?? ""
        return records(id, sql: "SELECT \(Self.columns) FROM files \(filter) ORDER BY seq LIMIT \(limit)") ?? []
    }

    func count(_ id: UUID, status: FileStatus) -> Int {
        var result = 0
        query(id, sql: "SELECT COUNT(*) FROM files WHERE status='\(status.rawValue)'") {
            result = Int(sqlite3_column_int64($0, 0))
        }
        return result
    }

    /// The first failed file carrying a diagnosis.
    func firstDiagnosedFailure(_ id: UUID) -> FileRecord? {
        records(id, sql: """
            SELECT \(Self.columns) FROM files
            WHERE status='failed' AND error_fix IS NOT NULL ORDER BY seq LIMIT 1
            """)?.first
    }

    func counters(_ id: UUID) -> ManifestCounters {
        var c = ManifestCounters()
        query(id, sql: """
            SELECT status, COUNT(*), SUM(CASE WHEN status IN ('copied','verified','skipped')
                THEN size ELSE bytes_copied END)
            FROM files GROUP BY status
            """) { row in
            let n = Int(sqlite3_column_int64(row, 1))
            let status = sqlite3_column_text(row, 0).map { FileStatus(rawValue: String(cString: $0)) } ?? nil
            c.doneBytes += sqlite3_column_int64(row, 2)
            switch status {
            case .copied: c.doneFiles += n
            case .verified: c.doneFiles += n; c.verifiedFiles = n
            case .skipped: c.doneFiles += n; c.skippedFiles = n
            case .failed: c.failedFiles = n
            default: break
            }
        }
        return c
    }

    // MARK: Plumbing

    private static let maxOpenConnections = 8

    private static let columns =
        "relative_path, size, mtime, status, bytes_copied, checksum, error, error_fix, error_icon"

    private static let schema = """
        CREATE TABLE IF NOT EXISTS files(
            seq INTEGER PRIMARY KEY, relative_path TEXT NOT NULL, size INTEGER NOT NULL,
            mtime REAL NOT NULL, status TEXT NOT NULL, bytes_copied INTEGER NOT NULL,
            checksum TEXT, error TEXT, error_fix TEXT, error_icon TEXT);
        """
    private static let statusIndex = "CREATE INDEX IF NOT EXISTS files_status ON files(status, seq);"

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func connect(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.sqlite(message)
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func upsert(_ db: OpaquePointer, _ changes: [FileChange]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO files(seq, \(columns)) VALUES(?,?,?,?,?,?,?,?,?,?)
            """, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        func bind(_ value: String?, _ slot: Int32) {
            if let value {
                sqlite3_bind_text(statement, slot, value, -1, transient)
            } else {
                sqlite3_bind_null(statement, slot)
            }
        }
        for change in changes {
            let r = change.record
            sqlite3_bind_int64(statement, 1, Int64(change.index))
            bind(r.relativePath, 2)
            sqlite3_bind_int64(statement, 3, r.size)
            sqlite3_bind_double(statement, 4, r.modificationDate.timeIntervalSinceReferenceDate)
            bind(r.status.rawValue, 5)
            sqlite3_bind_int64(statement, 6, r.bytesCopied)
            bind(r.checksum, 7)
            bind(r.error, 8)
            bind(r.errorFix, 9)
            bind(r.errorIcon, 10)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(statement)
        }
    }

    /// The job's connection, opened in WAL mode on first use. Queue only.
    private func connection(_ id: UUID, create: Bool = false) -> OpaquePointer? {
        if let db = open[id] { return db }
        guard create || FileManager.default.fileExists(atPath: url(id).path),
              let db = try? Self.connect(url(id)) else { return nil }
        // NORMAL + WAL survives a process kill and only fsyncs at checkpoints.
        try? Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        if create { try? Self.exec(db, Self.schema + Self.statusIndex) }
        // Each connection holds three descriptors; browsing history mustn't
        // accumulate them. Evicting an active job's just costs a reopen.
        if open.count >= Self.maxOpenConnections, let evicted = open.keys.first {
            closeConnection(evicted)
        }
        open[id] = db
        return db
    }

    private func closeConnection(_ id: UUID) {
        if let db = open.removeValue(forKey: id) { sqlite3_close(db) }
    }

    private func removeSidecars(_ target: URL) {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: target.path + suffix)
        }
    }

    private func query(_ id: UUID, sql: String, row: (OpaquePointer) -> Void) {
        _ = queue.sync { () -> Bool in
            guard let db = connection(id) else { return false }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return false }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
            return true
        }
    }

    private func records(_ id: UUID, sql: String) -> [FileRecord]? {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
        var result: [FileRecord] = []
        func text(_ row: OpaquePointer, _ column: Int32) -> String? {
            sqlite3_column_text(row, column).map { String(cString: $0) }
        }
        query(id, sql: sql) { row in
            result.append(FileRecord(
                relativePath: text(row, 0) ?? "",
                size: sqlite3_column_int64(row, 1),
                modificationDate: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2)),
                status: FileStatus(rawValue: text(row, 3) ?? "") ?? .pending,
                bytesCopied: sqlite3_column_int64(row, 4),
                checksum: text(row, 5),
                error: text(row, 6),
                errorFix: text(row, 7),
                errorIcon: text(row, 8)))
        }
        return result
    }
}
