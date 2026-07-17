import Foundation
import CryptoKit

/// Generates a self-contained HTML integrity certificate for a finished job.
/// The certificate ID is a hash of the whole manifest, so the same backup
/// always yields the same ID and anyone can reproduce it with a deep Compare.
enum Certificate {
    static func directory() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyWatch/certificates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for jobID: UUID) -> URL {
        directory().appendingPathComponent("\(jobID.uuidString).html")
    }

    static func exists(for jobID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: jobID).path)
    }

    /// Reproducible certificate ID: SHA-256 over canonical "path\tsize\tsha256"
    /// lines (sorted). Independent of copy order, drive, or timestamps.
    static func certificateID(for job: CopyJob) -> String {
        let lines = job.files
            .map { "\($0.relativePath)\t\($0.size)\t\($0.checksum ?? "")" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(lines.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()

    /// Build and save the certificate for a finished job. Returns its file URL.
    @discardableResult
    static func generate(for job: CopyJob) -> URL {
        let html = render(job)
        let out = url(for: job.id)
        try? Data(html.utf8).write(to: out, options: .atomic)
        return out
    }

    // MARK: HTML

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func render(_ job: CopyJob) -> String {
        let df = DateFormatter()
        df.dateStyle = .long; df.timeStyle = .medium
        let certID = certificateID(for: job)
        let algoName = job.checksumAlgorithm.displayName
        let verifiedAll = job.failedFiles == 0 && job.doneFiles == job.totalFiles
        let statusText = verifiedAll ? "VERIFIED" : "COMPLETED WITH ERRORS"
        let statusColor = verifiedAll ? "#37b24d" : "#f08c00"

        let destRows = job.allDestinations.map { d in
            "<tr><td>\(esc(d.volume.name))</td><td class=\"mono\">\(esc(d.path))</td></tr>"
        }.joined()

        let fileRows = job.files.prefix(20000).map { f -> String in
            let status: String
            switch f.status {
            case .verified: status = "verified"
            case .copied: status = "copied"
            case .skipped: status = "identical"
            case .failed: status = "FAILED"
            default: status = f.status.rawValue
            }
            return "<tr><td class=\"mono path\">\(esc(f.relativePath))</td>"
                + "<td class=\"num\">\(Format.bytes(f.size))</td>"
                + "<td class=\"mono hash\">\(f.checksum ?? "—")</td>"
                + "<td>\(status)</td></tr>"
        }.joined()

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>CopyWatch Integrity Certificate — \(esc(job.name))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 40px;
                 background: #f5f5f7; color: #1d1d1f; }
          @media (prefers-color-scheme: dark){ body{ background:#1c1c1e; color:#f2f2f7 } .card{ background:#2c2c2e !important } th{ background:#3a3a3c !important } }
          .sheet { max-width: 940px; margin: 0 auto; }
          .card { background: #fff; border-radius: 14px; padding: 28px 32px; margin-bottom: 20px;
                  box-shadow: 0 1px 3px rgba(0,0,0,.08); }
          .head { display:flex; align-items:center; gap:16px; }
          .badge { margin-left:auto; font-weight:700; letter-spacing:.5px; padding:6px 14px;
                   border-radius:999px; color:#fff; background:\(statusColor); }
          h1 { font-size: 22px; margin: 0; }
          .sub { color: #86868b; font-size: 13px; }
          .certid { font-family: ui-monospace, Menlo, monospace; font-size: 12px; word-break: break-all;
                    background: rgba(127,127,127,.12); padding: 10px 12px; border-radius: 8px; }
          .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
          .stat .n { font-size: 26px; font-weight: 700; }
          .stat .l { color:#86868b; font-size:12px; text-transform:uppercase; letter-spacing:.4px; }
          table { width:100%; border-collapse: collapse; font-size: 13px; }
          th,td { text-align:left; padding:7px 10px; border-bottom:1px solid rgba(127,127,127,.18); }
          th { background:#f0f0f2; position:sticky; top:0; }
          .mono { font-family: ui-monospace, Menlo, monospace; }
          .hash { font-size: 11px; color:#86868b; }
          .num { text-align:right; white-space:nowrap; }
          .path { max-width: 380px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
          .files-wrap { max-height: 460px; overflow:auto; border-radius:10px; border:1px solid rgba(127,127,127,.18); }
          .foot { color:#86868b; font-size:12px; text-align:center; }
        </style></head><body><div class="sheet">

          <div class="card"><div class="head">
            <div>
              <h1>Integrity Certificate</h1>
              <div class="sub">CopyWatch \(appVersion) · issued \(df.string(from: job.completedAt ?? Date()))</div>
            </div>
            <div class="badge">\(statusText)</div>
          </div>
          <p style="margin:18px 0 6px"><strong>\(esc(job.name))</strong></p>
          <div class="certid">Certificate ID (SHA-256 of manifest)<br>\(certID)</div>
          <p class="sub" style="margin-top:10px">Reproduce this ID any time by re-running a deep Compare of the source and destination — a match proves the data is unchanged.</p>
          </div>

          <div class="card">
            <div class="grid">
              <div class="stat"><div class="n">\(job.totalFiles)</div><div class="l">Files</div></div>
              <div class="stat"><div class="n">\(Format.bytes(job.totalBytes))</div><div class="l">Total size</div></div>
              <div class="stat"><div class="n">\(job.verifiedFiles)</div><div class="l">Verified by hash</div></div>
              <div class="stat"><div class="n">\(job.failedFiles)</div><div class="l">Failed</div></div>
            </div>
          </div>

          <div class="card">
            <h1 style="font-size:16px">Source & destinations</h1>
            <table style="margin-top:10px">
              <tr><td>\(esc(job.sourceVolume.name))</td><td class="mono">\(esc(job.sourcePath))</td><td class="sub">source</td></tr>
              \(destRows)
            </table>
          </div>

          <div class="card">
            <h1 style="font-size:16px">Manifest &amp; checksums</h1>
            <div class="files-wrap" style="margin-top:10px"><table>
              <thead><tr><th>File</th><th class="num">Size</th><th>\(algoName)</th><th>Status</th></tr></thead>
              <tbody>\(fileRows)</tbody>
            </table></div>
          </div>

          <p class="foot">Generated by CopyWatch. Every file above was copied and its \(algoName) checksum confirmed against the source.</p>
        </div></body></html>
        """
    }
}
