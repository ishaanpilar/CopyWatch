import Foundation

enum Format {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s left" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s left" }
        return "\(s / 3600)h \((s % 3600) / 60)m left"
    }

    static func csv(for job: CopyJob) -> String {
        var lines = ["relative_path,size_bytes,status,sha256,error"]
        for f in job.files {
            let path = f.relativePath.contains(",") || f.relativePath.contains("\"")
                ? "\"\(f.relativePath.replacingOccurrences(of: "\"", with: "\"\""))\""
                : f.relativePath
            lines.append("\(path),\(f.size),\(f.status.rawValue),\(f.checksum ?? ""),\(f.error ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static func csv(for record: ComparisonRecord) -> String {
        var lines = ["state,relative_path"]
        for p in record.missing { lines.append("missing,\(p)") }
        for p in record.differing { lines.append("differs,\(p)") }
        for p in record.extras { lines.append("extra_in_destination,\(p)") }
        return lines.joined(separator: "\n")
    }
}
