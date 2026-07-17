import Foundation

/// Development diagnostics. When enabled, appends timestamped JSON-line events
/// describing a transfer's throughput and latencies to a file under
/// …/CopyWatch/Logs, so a slow or stuttering copy can be analyzed after the
/// fact instead of guessed at.
///
/// Disabled by default. Turn it on with the in-app Diagnostics toggle
/// (persisted in `UserDefaults` key `diagnosticsEnabled`) or, for headless
/// runs, the `COPYWATCH_DIAG=1` environment variable. Every write happens on a
/// private queue and timestamps are captured at the call site, so the logging
/// itself barely perturbs the transfer it is measuring.
final class TransferLog: @unchecked Sendable {
    static let shared = TransferLog()

    private let queue = DispatchQueue(label: "com.copywatch.diag", qos: .utility)
    private var handle: FileHandle?
    private var t0 = DispatchTime.now()
    private(set) var active = false
    private(set) var currentURL: URL?

    static var isEnabledByDefault: Bool {
        ProcessInfo.processInfo.environment["COPYWATCH_DIAG"] == "1"
        || UserDefaults.standard.bool(forKey: "diagnosticsEnabled")
    }

    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyWatch/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Monotonic seconds since the current log began. Captured at the call site.
    private func nowSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e9
    }

    /// Open a fresh log file for one job run. No-op (returns nil) when disabled.
    @discardableResult
    func begin(label: String) -> URL? {
        guard Self.isEnabledByDefault else { return nil }
        return queue.sync {
            let stamp = Self.stamp()
            let file = Self.directory.appendingPathComponent("transfer-\(stamp).jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try? FileHandle(forWritingTo: file)
            currentURL = file
            t0 = DispatchTime.now()
            active = handle != nil
            writeLine(["event": "begin", "label": label, "wall": stamp,
                       "t": 0.0])
            return active ? file : nil
        }
    }

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard active else { return }
        let t = nowSeconds()
        queue.async { [self] in
            guard handle != nil else { return }
            var obj = fields
            obj["event"] = event
            obj["t"] = (t * 1000).rounded() / 1000
            writeLine(obj)
        }
    }

    func end() {
        guard active else { return }
        queue.sync { [self] in
            writeLine(["event": "end", "t": nowSeconds()])
            try? handle?.close()
            handle = nil
            active = false
        }
    }

    private func writeLine(_ obj: [String: Any]) {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
