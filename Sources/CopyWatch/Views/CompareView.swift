import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone folder-vs-folder comparison, plus the saved comparison history.
struct CompareView: View {
    @Environment(AppState.self) private var appState

    @State private var pathA = ""
    @State private var pathB = ""
    @State private var deep = false
    @State private var expanded: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                form
                Divider()
                history
            }
            .padding()
        }
        .navigationTitle("Compare Folders")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare two folders").font(.title3.bold())
            Text("Checks the things you'd check by hand — file counts, total size — and exactly which files are missing, different, or extra.")
                .font(.callout)
                .foregroundStyle(.secondary)

            picker(label: "Original (A)", path: $pathA)
            picker(label: "Copy (B)", path: $pathB)

            Toggle(isOn: $deep) {
                VStack(alignment: .leading) {
                    Text("Deep compare (checksums)")
                    Text("Hashes every file on both sides. Slower, but catches corruption that size and dates can't.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    appState.runCompare(pathA: pathA, pathB: pathB, deep: deep)
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(pathA.isEmpty || pathB.isEmpty || appState.compareRunning)

                if appState.compareRunning {
                    ProgressView().controlSize(.small)
                }
                Text(appState.compareStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Past comparisons").font(.headline)
            if appState.comparisons.isEmpty {
                Text("No comparisons yet.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(appState.comparisons) { record in
                ComparisonCard(
                    record: record,
                    isExpanded: expanded == record.id,
                    toggle: { expanded = (expanded == record.id) ? nil : record.id },
                    delete: { appState.deleteComparison(record.id) }
                )
            }
        }
    }

    private func picker(label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .trailing).font(.callout)
            TextField("Folder path", text: path)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
        }
    }
}

struct ComparisonCard: View {
    let record: ComparisonRecord
    let isExpanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: record.isIdentical
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(record.isIdentical ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\((record.pathA as NSString).lastPathComponent) ↔ \((record.pathB as NSString).lastPathComponent)")
                        .font(.headline)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened) +
                         (record.deep ? " · deep (checksums)" : " · quick"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isExpanded ? "Hide details" : "Details") { toggle() }
                    .buttonStyle(.link)
                Menu {
                    Button("Export CSV…") { exportCSV() }
                    Button("Delete", role: .destructive) { delete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 16) {
                summary("A", files: record.filesA, bytes: record.bytesA)
                summary("B", files: record.filesB, bytes: record.bytesB)
                if record.isIdentical {
                    Text("Identical ✓").foregroundStyle(.green).font(.callout.bold())
                } else {
                    Text("\(record.missing.count) missing · \(record.differing.count) differ · \(record.extras.count) extra")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if isExpanded && !record.isIdentical {
                detailLists
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summary(_ side: String, files: Int, bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Text(side).font(.caption.bold()).foregroundStyle(.secondary)
            Text("\(files) files, \(Format.bytes(bytes))").font(.callout).monospacedDigit()
        }
    }

    @ViewBuilder private var detailLists: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailSection("Missing in B", items: record.missing, color: .red)
            detailSection("Different", items: record.differing, color: .orange)
            detailSection("Extra in B", items: record.extras, color: .secondary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func detailSection(_ title: String, items: [String], color: Color) -> some View {
        if !items.isEmpty {
            Text("\(title) (\(items.count))").font(.caption.bold()).foregroundStyle(color)
            ForEach(items.prefix(200), id: \.self) { path in
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if items.count > 200 {
                Text("… and \(items.count - 200) more — export CSV for the full list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "comparison.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Format.csv(for: record).data(using: .utf8)?.write(to: url)
    }
}
