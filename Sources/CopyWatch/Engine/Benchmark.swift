import Foundation

/// Measures a drive's real write and read throughput by moving a temp file with
/// the OS cache bypassed (F_NOCACHE), so results reflect the hardware rather
/// than RAM. Also pulls SMART status / connection type from `diskutil`.
enum Benchmark {
    static let chunkSize = 8 * 1024 * 1024

    enum Phase: Equatable {
        case preparing
        case writing(Double)   // fraction
        case reading(Double)
        case finishing
    }

    /// Run the benchmark for the volume at `volumePath`, writing a `testBytes`
    /// scratch file. Reports progress; returns the result.
    static func run(
        volumeName: String, volumePath: String, volumeUUID: String?,
        testBytes: Int64 = 512 * 1024 * 1024,
        progress: @escaping (Phase) -> Void
    ) throws -> BenchmarkResult {
        progress(.preparing)
        let scratch = URL(fileURLWithPath: volumePath)
            .appendingPathComponent(".copywatch-benchmark-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let buffer = Data(count: chunkSize)  // zero-filled is fine for throughput
        let chunks = Int((testBytes + Int64(chunkSize) - 1) / Int64(chunkSize))

        // WRITE (cache-bypassed)
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        let wfd = open(scratch.path, O_WRONLY)
        guard wfd >= 0 else { throw posix("Could not create a test file on this drive") }
        _ = fcntl(wfd, F_NOCACHE, 1)
        let writeStart = Date()
        try buffer.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for i in 0..<chunks {
                try Task.checkCancellation()
                var written = 0
                while written < chunkSize {
                    let n = write(wfd, base + written, chunkSize - written)
                    if n <= 0 { close(wfd); throw posix("Write failed — the drive may be full or failing") }
                    written += n
                }
                progress(.writing(Double(i + 1) / Double(chunks)))
            }
        }
        _ = fcntl(wfd, F_FULLFSYNC, 0)   // force everything to the platters/flash
        close(wfd)
        let writeElapsed = max(Date().timeIntervalSince(writeStart), 0.001)
        let writeBps = Double(Int64(chunks) * Int64(chunkSize)) / writeElapsed

        // READ (cache-bypassed)
        let rfd = open(scratch.path, O_RDONLY)
        guard rfd >= 0 else { throw posix("Could not read the test file back") }
        _ = fcntl(rfd, F_NOCACHE, 1)
        var readBuf = [UInt8](repeating: 0, count: chunkSize)
        let readStart = Date()
        var totalRead = 0
        readLoop: while true {
            try Task.checkCancellation()
            let n = readBuf.withUnsafeMutableBytes { read(rfd, $0.baseAddress, chunkSize) }
            if n <= 0 { break readLoop }
            totalRead += n
            progress(.reading(Double(totalRead) / Double(chunks * chunkSize)))
        }
        close(rfd)
        let readElapsed = max(Date().timeIntervalSince(readStart), 0.001)
        let readBps = Double(totalRead) / readElapsed

        progress(.finishing)
        let info = diskInfo(volumePath: volumePath)

        return BenchmarkResult(
            id: UUID(), date: Date(),
            volumeName: volumeName, volumePath: volumePath, volumeUUID: volumeUUID,
            writeBytesPerSec: writeBps, readBytesPerSec: readBps,
            testBytes: Int64(chunks) * Int64(chunkSize),
            smartStatus: info.smart, connection: info.connection, isSolidState: info.ssd)
    }

    // MARK: diskutil

    private static func diskInfo(volumePath: String) -> (smart: String?, connection: String?, ssd: Bool?) {
        let out = shell("/usr/sbin/diskutil", ["info", volumePath])
        guard let out else { return (nil, nil, nil) }
        func field(_ key: String) -> String? {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        let smart = field("SMART Status")
        let connection = field("Protocol")
        let ssd = field("Solid State").map { $0.lowercased().hasPrefix("yes") }
        return (smart, connection, ssd)
    }

    private static func shell(_ launch: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func posix(_ message: String) -> NSError {
        NSError(domain: "CopyWatch.Benchmark", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
