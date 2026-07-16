import Foundation

/// Reads the throughput profile of a running copy and, when it has slowed down,
/// explains the most likely reason — the "why is this slow?" intelligence.
enum SpeedAnalyzer {
    struct Note: Equatable {
        let text: String
        let icon: String
        let isProblem: Bool   // orange vs. informational
    }

    /// `history` is MB/s samples (~1/sec). `avgFileBytes` and `currentFile`
    /// give context to distinguish causes.
    static func analyze(
        history: [Double], avgFileBytes: Int64, currentFile: String?, verifying: Bool
    ) -> Note? {
        guard history.count >= 6 else { return nil }   // need a few seconds of data
        let current = recentAverage(history, count: 3)
        let peak = history.max() ?? 0
        guard peak > 5 else { return nil }             // ignore trivially slow tiny jobs

        // Verifying phase — expected pause between/after writes.
        if verifying {
            return Note(
                text: "Verifying — reading files back to confirm their checksums. This is expected and not a transfer problem.",
                icon: "checkmark.shield", isProblem: false)
        }

        // Not actually slow.
        if current >= 0.72 * peak {
            return nil
        }

        // Many small files: per-file overhead dominates, throughput looks low.
        if avgFileBytes > 0 && avgFileBytes < 4 * 1024 * 1024 {
            return Note(
                text: "Copying lots of small files — most of the time goes to per-file overhead, not data, so MB/s looks low. This is normal and not a drive problem.",
                icon: "doc.on.doc", isProblem: false)
        }

        // Recovering: the last sample is climbing back toward peak.
        if history.count >= 4 {
            let veryRecent = history.suffix(2).reduce(0, +) / 2
            let beforeThat = history.suffix(5).prefix(3).reduce(0, +) / 3
            if veryRecent > beforeThat * 1.25 {
                return Note(
                    text: "Speed is recovering after a brief dip — likely another app was using the disk, or a momentary connection hiccup.",
                    icon: "arrow.up.right", isProblem: false)
            }
        }

        // Sustained drop from a high plateau that stays low → SSD write-cache
        // exhaustion (started fast, then dropped and held).
        let earlyPeak = history.prefix(max(history.count / 3, 3)).max() ?? peak
        let sustainedLow = history.suffix(4).allSatisfy { $0 < 0.7 * earlyPeak }
        if sustainedLow && earlyPeak > 0.9 * peak {
            return Note(
                text: "Started fast, now steady and slower — the destination drive's fast write cache has filled, so it's writing at its native sustained speed. Normal for large transfers; nothing is wrong.",
                icon: "gauge.with.dots.needle.33percent", isProblem: false)
        }

        // Generic slowdown we can't pin down.
        return Note(
            text: "Running slower than it started. Common causes: a slower or busy destination drive, a hub or long cable, or another app using the disk. Try a Transfer Benchmark on the destination to check its health.",
            icon: "tortoise", isProblem: true)
    }

    private static func recentAverage(_ history: [Double], count: Int) -> Double {
        let tail = history.suffix(count)
        return tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
    }
}
