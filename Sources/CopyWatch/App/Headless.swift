import Foundation

/// CLI mode for driving the engine without the GUI — used for testing.
///
///   CopyWatch --headless copy <source> <destParent> [<destParent2> …] [--no-verify]
///   CopyWatch --headless compare <a> <b> [--deep]
enum Headless {
    static func main(_ args: [String]) -> Never {
        switch args.first {
        case "copy" where args.count >= 3:
            let parents = args[2...].filter { !$0.hasPrefix("--") }
            runCopy(source: args[1], destParents: Array(parents), verify: !args.contains("--no-verify"))
        case "compare" where args.count >= 3:
            runCompare(a: args[1], b: args[2], deep: args.contains("--deep"))
        default:
            FileHandle.standardError.write(Data("""
            usage: CopyWatch --headless copy <source> <destParent> [<destParent2> …] [--no-verify]
                   CopyWatch --headless compare <a> <b> [--deep]
            \n
            """.utf8))
            exit(64)
        }
    }

    private static func runCopy(source: String, destParents: [String], verify: Bool) -> Never {
        let store = JobStore()
        func destPath(_ parent: String) -> String {
            (parent as NSString).appendingPathComponent((source as NSString).lastPathComponent)
        }

        var job = CopyJob(
            id: UUID(),
            name: CopyJob.defaultName(source: source, dest: destPath(destParents[0])),
            sourceVolume: .forPath(source),
            destVolume: .forPath(destParents[0]),
            sourcePath: source,
            destPath: destPath(destParents[0])
        )
        job.extraDestinations = destParents.dropFirst().map {
            JobDestination(volume: .forPath($0), path: destPath($0))
        }
        job.verifyAfterCopy = verify

        print("Scanning \(source)…")
        do {
            job.files = try Scanner.scan(root: URL(fileURLWithPath: source))
        } catch {
            print("Scan failed: \(error.localizedDescription)")
            exit(1)
        }
        job.totalFiles = job.files.count
        job.totalBytes = job.files.reduce(0) { $0 + $1.size }
        job.status = .ready
        print("Manifest: \(job.totalFiles) files, \(Format.bytes(job.totalBytes))")

        let done = DispatchSemaphore(value: 0)
        let engine = JobEngine(job: job) { snapshot in
            store.save(snapshot, force: !snapshot.status.isActive)
            if let current = snapshot.currentFile {
                print("[\(Int(snapshot.fractionDone * 100))%] " +
                      "\(Format.bytes(snapshot.doneBytes))/\(Format.bytes(snapshot.totalBytes)) " +
                      "\(Format.speed(snapshot.bytesPerSecond))  \(current)")
            }
            switch snapshot.status {
            case .completed, .completedWithErrors, .cancelled,
                 .waitingForVolume, .paused, .interrupted:
                done.signal()
            default: break
            }
        }
        engine.start()
        done.wait()

        let final = engine.job
        store.save(final, force: true)
        var certLine = ""
        if final.status == .completed || final.status == .completedWithErrors {
            let url = Certificate.generate(for: final)
            certLine = "\n  certificate: \(url.path)\n  cert ID:     \(Certificate.certificateID(for: final))"
        }
        print("""

        Result: \(final.status.label)\(final.statusMessage.map { " — \($0)" } ?? "")
          copied:   \(final.doneFiles - final.skippedFiles)
          skipped:  \(final.skippedFiles) (already at destination)
          verified: \(final.verifiedFiles)
          failed:   \(final.failedFiles)
          bytes:    \(Format.bytes(final.doneBytes)) / \(Format.bytes(final.totalBytes))\(certLine)
        """)
        exit(final.status == .completed ? 0 : 1)
    }

    private static func runCompare(a: String, b: String, deep: Bool) -> Never {
        do {
            let report = try Reconciler.compare(
                a: URL(fileURLWithPath: a), b: URL(fileURLWithPath: b), deep: deep
            ) { status in print(status) }
            JobStore().save(report)
            print("""

            A: \(report.filesA) files, \(Format.bytes(report.bytesA)) — \(a)
            B: \(report.filesB) files, \(Format.bytes(report.bytesB)) — \(b)
            matched: \(report.matched)
            missing in B: \(report.missing.count)\(report.missing.isEmpty ? "" : "  " + report.missing.joined(separator: ", "))
            differing:    \(report.differing.count)\(report.differing.isEmpty ? "" : "  " + report.differing.joined(separator: ", "))
            extras in B:  \(report.extras.count)\(report.extras.isEmpty ? "" : "  " + report.extras.joined(separator: ", "))
            \(report.isIdentical ? "IDENTICAL ✓" : "DIFFERENT ✗")
            """)
            exit(report.isIdentical ? 0 : 2)
        } catch {
            print("Compare failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
