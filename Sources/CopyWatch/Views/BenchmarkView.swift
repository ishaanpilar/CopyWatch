import SwiftUI

/// Measure a drive's real read/write speed and health — useful for diagnosing
/// a slow backup or catching a drive that's starting to fail.
struct BenchmarkView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPath: String?
    @State private var testSizeMB = 512

    private var drives: [MountedVolume] {
        appState.volumes.sorted { ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transfer Benchmark").font(.title2.bold())
                    Text("Writes and reads a temporary test file with the OS cache bypassed, so you see the drive's real speed — not RAM. A copy running far below these numbers points to a cable, hub, or a failing drive.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Drive", selection: $selectedPath) {
                                Text("Choose a drive").tag(String?.none)
                                ForEach(drives) { d in
                                    Text("\(d.name)\(d.isInternal ? " (internal)" : "")")
                                        .tag(String?.some(d.path))
                                }
                            }
                            Picker("Test size", selection: $testSizeMB) {
                                Text("256 MB").tag(256)
                                Text("512 MB").tag(512)
                                Text("1 GB").tag(1024)
                                Text("2 GB").tag(2048)
                            }
                            .fixedSize()
                        }

                        if appState.benchmarkRunning {
                            benchmarkProgress
                        } else {
                            Button {
                                if let path = selectedPath, let vol = drives.first(where: { $0.path == path }) {
                                    appState.runBenchmark(vol, testBytes: Int64(testSizeMB) * 1024 * 1024)
                                }
                            } label: {
                                Label("Run Benchmark", systemImage: "gauge.with.dots.needle.67percent")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPath == nil)
                        }

                        if let err = appState.benchmarkError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                    }
                    .padding(6)
                }

                if !appState.benchmarks.isEmpty {
                    Text("Results").font(.headline)
                    ForEach(appState.benchmarks) { result in
                        BenchmarkCard(result: result) { appState.deleteBenchmark(result.id) }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Benchmark")
    }

    @ViewBuilder private var benchmarkProgress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            switch appState.benchmarkPhase {
            case .preparing: Text("Preparing…")
            case .writing(let f): Text("Writing… \(Int(f * 100))%")
            case .reading(let f): Text("Reading… \(Int(f * 100))%")
            case .finishing, .none: Text("Finishing…")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

private struct BenchmarkCard: View {
    let result: BenchmarkResult
    let delete: () -> Void

    private func mbps(_ v: Double) -> String { String(format: "%.0f MB/s", v / 1_000_000) }

    private var ratingColor: Color {
        switch result.rating {
        case "Excellent": .green
        case "Good": .blue
        case "Fair": .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: result.isSolidState == false ? "internaldrive" : "externaldrive.fill")
                    .foregroundStyle(.secondary)
                Text(result.volumeName).font(.headline)
                Text(result.rating)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ratingColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(ratingColor)
                Spacer()
                Text(result.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Delete", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 24) {
                metric("Write", mbps(result.writeBytesPerSec), "arrow.down.to.line")
                metric("Read", mbps(result.readBytesPerSec), "arrow.up.from.line")
                if let smart = result.smartStatus {
                    metric("SMART", smart, "heart.text.square")
                }
                if let conn = result.connection {
                    metric("Connection", conn, "cable.connector")
                }
            }
        }
        .padding(12)
        .background(Color(.quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold()).monospacedDigit()
        }
    }
}
