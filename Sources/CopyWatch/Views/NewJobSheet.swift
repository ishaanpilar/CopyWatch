import SwiftUI
import AppKit

struct NewJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    /// (sources, destinationParents, verify, checksumAlgorithm)
    let onCreate: ([String], [String], Bool, ChecksumAlgorithm) -> Void
    var onPickDevice: ((String) -> Void)?

    @State private var sourcePaths: [String]
    @State private var destParentPaths: [String]
    @State private var verify = false
    @State private var algorithm: ChecksumAlgorithm = .sha256
    @State private var saveAsPreset = false

    init(initialSources: [String] = [], initialDests: [String] = [],
         onCreate: @escaping ([String], [String], Bool, ChecksumAlgorithm) -> Void,
         onPickDevice: ((String) -> Void)? = nil) {
        self.onCreate = onCreate
        self.onPickDevice = onPickDevice
        _sourcePaths = State(initialValue: initialSources)
        _destParentPaths = State(initialValue: initialDests)
    }

    private var sourceSummary: String {
        switch sourcePaths.count {
        case 0: ""
        case 1: sourcePaths[0]
        default: "\(sourcePaths.count) items selected"
        }
    }

    private var canStart: Bool {
        !sourcePaths.isEmpty && !destParentPaths.isEmpty
            && Set(destParentPaths).isDisjoint(with: Set(sourcePaths))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Copy Job").font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("From").frame(width: 44, alignment: .trailing)
                TextField("Camera card, folder, or files", text: .constant(sourceSummary))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Choose") { chooseSource() }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Copy to").font(.callout)
                    if destParentPaths.count > 1 {
                        Text("copies to all \(destParentPaths.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        chooseDest(replacingIndex: nil)
                    } label: {
                        Label("Add destination", systemImage: "plus")
                    }
                    .font(.caption)
                }

                if destParentPaths.isEmpty {
                    Button {
                        chooseDest(replacingIndex: nil)
                    } label: {
                        Label("Choose a destination folder", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(destParentPaths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                destParentPaths.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(.quaternaryLabelColor).opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Verify every file after copying", isOn: $verify)
                    Text("Checksums each copy against the source. About 2× slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Picker("Checksum", selection: $algorithm) {
                        ForEach(ChecksumAlgorithm.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help(algorithm.blurb)
                    Text(algorithm.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !destParentPaths.isEmpty {
                Toggle("Save as destination preset", isOn: $saveAsPreset)
                    .help("Reuse it later from the drop prompt and the Destinations tab")
            }

            HStack {
                ForEach(appState.devices) { device in
                    Button("Back up “\(device.name)” instead") {
                        dismiss()
                        onPickDevice?(device.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("iPhones and cameras aren't disks — they have their own backup flow")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Copy") {
                    if saveAsPreset {
                        let name = destParentPaths.count > 1
                            ? "\(destParentPaths.count) drives"
                            : (destParentPaths[0] as NSString).lastPathComponent
                        appState.addDestinationPreset(name: name, paths: destParentPaths)
                    }
                    onCreate(sourcePaths, destParentPaths, verify, algorithm)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Select"
        panel.message = "Choose a folder, or select individual files and folders together."
        if panel.runModal() == .OK {
            sourcePaths = panel.urls.map(\.path)
        }
    }

    private func chooseDest(replacingIndex: Int?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a folder to copy into."
        if panel.runModal() == .OK, let url = panel.url {
            if !destParentPaths.contains(url.path) {
                destParentPaths.append(url.path)
            }
        }
    }
}
