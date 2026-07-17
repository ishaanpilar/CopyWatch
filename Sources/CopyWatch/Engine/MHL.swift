import Foundation

/// Media Hash List export — the interchange manifest the film/broadcast industry
/// uses to carry per-file checksums between offload tools (Hedge, ShotPut Pro,
/// Silverstack, DaVinci Resolve, YoYotta). We write classic MHL v1.1: an `.mhl`
/// file whose relative paths are resolved against wherever the file is saved, so
/// dropping it at the destination root makes every copied file verifiable by any
/// MHL-aware tool.
enum MHL {
    /// The MHL hash-element tag for a given algorithm. Classic MHL uses
    /// `xxhash64`; `sha256` is accepted by ASC-MHL-aware parsers.
    private static func tag(for algorithm: ChecksumAlgorithm) -> String {
        switch algorithm {
        case .xxh64: return "xxhash64"
        case .sha256: return "sha256"
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// A default filename for a job's MHL, e.g. "DCIM_2026-07-17.mhl".
    static func suggestedFileName(for job: CopyJob) -> String {
        let base = (job.destPath as NSString).lastPathComponent
        let stamp = DateFormatter.mhlStamp.string(from: job.completedAt ?? Date())
        return "\(base.isEmpty ? "CopyWatch" : base)_\(stamp).mhl"
    }

    /// Render the MHL XML for a finished job. Only files that were copied and
    /// carry a checksum are listed.
    static func render(_ job: CopyJob) -> String {
        let hashTag = tag(for: job.checksumAlgorithm)
        let now = iso.string(from: Date())
        let start = iso.string(from: job.createdAt)
        let finish = iso.string(from: job.completedAt ?? Date())

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <name>\(esc(job.name))</name>
            <username>\(esc(NSUserName()))</username>
            <hostname>\(esc(ProcessInfo.processInfo.hostName))</hostname>
            <tool>CopyWatch \(esc(appVersion))</tool>
            <startdate>\(start)</startdate>
            <finishdate>\(finish)</finishdate>
          </creatorinfo>

        """

        for f in job.files where f.isDone && f.checksum != nil {
            xml += """
              <hash>
                <file>\(esc(f.relativePath))</file>
                <size>\(f.size)</size>
                <lastmodificationdate>\(iso.string(from: f.modificationDate))</lastmodificationdate>
                <\(hashTag)>\(f.checksum!)</\(hashTag)>
                <hashdate>\(now)</hashdate>
              </hash>

            """
        }
        xml += "</hashlist>\n"
        return xml
    }
}

private extension DateFormatter {
    static let mhlStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
