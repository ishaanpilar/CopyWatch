import SwiftUI
import AppKit

/// The confirm step of a copy: what you picked → where it goes → Start.
/// Deliberately minimal — verify, checksum, extra drives, and presets live
/// behind Options so a first-time user sees exactly one decision.
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
    @State private var showOptions = false

    init(initialSources: [String] = [], initialDests: [String] = [],
         onCreate: @escaping ([String], [String], Bool, ChecksumAlgorithm) -> Void,
         onPickDevice: ((String) -> Void)? = nil) {
        self.onCreate = onCreate
        self.onPickDevice = onPickDevice
        _sourcePaths = State(initialValue: initialSources)
        _destParentPaths = State(initialValue: initialDests)
    }

    private var canStart: Bool {
        !sourcePaths.isEmpty && !destParentPaths.isEmpty
            && Set(destParentPaths).isDisjoint(with: Set(sourcePaths))
    }

    /// Why Start Copy is disabled — shown beside it so the user isn't left
    /// guessing at a greyed-out button.
    private var missingStepHint: String? {
        if sourcePaths.isEmpty { return "Choose what to copy" }
        if destParentPaths.isEmpty { return "Where should it go?" }
        if !Set(destParentPaths).isDisjoint(with: Set(sourcePaths)) {
            return "Source and destination are the same folder"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Copy Job").font(.headline)

            sourceRow

            destinationPicker

            DisclosureGroup(isExpanded: $showOptions) {
                optionsContent
            } label: {
                Text("Options")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ForEach(appState.devices) { device in
                    Button("Back up “\(device.name)” instead") {
                        dismiss()
                        onPickDevice?(device.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
                if let hint = missingStepHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .frame(width: 460)
    }

    // MARK: What's being copied — a quiet, already-answered row

    private var sourceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: sourcePaths.count == 1 && isDirectory(sourcePaths[0])
                  ? "folder.fill" : "doc.on.doc.fill")
                .foregroundStyle(.tint)
            if sourcePaths.isEmpty {
                Text("Nothing selected yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sourceName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(sourceDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(sourcePaths.isEmpty ? "Choose…" : "Change") { chooseSource() }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourceName: String {
        sourcePaths.count == 1
            ? (sourcePaths[0] as NSString).lastPathComponent
            : "\(sourcePaths.count) items"
    }

    private var sourceDetail: String {
        sourcePaths.count == 1
            ? (sourcePaths[0] as NSString).deletingLastPathComponent
            : sourcePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    private func isDirectory(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true
    }

    // MARK: Where it goes — the one decision on this sheet

    @ViewBuilder private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Copy to")
                .font(.callout.weight(.medium))

            if destParentPaths.isEmpty {
                // Saved destinations answer in one click.
                ForEach(appState.destinationPresets) { preset in
                    Button {
                        destParentPaths = preset.allPaths
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.isMulti ? "square.stack.3d.up.fill" : "externaldrive.fill")
                                .foregroundStyle(preset.isDefault ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name).font(.callout.weight(.medium))
                                Text(preset.isMulti
                                     ? preset.allPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                                     : preset.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Color(.quaternaryLabelColor).opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    chooseDest()
                } label: {
                    Label(appState.destinationPresets.isEmpty
                          ? "Choose a Folder"
                          : "Somewhere Else…",
                          systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                ForEach(Array(destParentPaths.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                                .font(.callout.weight(.medium))
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            destParentPaths.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this destination")
                    }
                    .padding(10)
                    .background(Color(.quaternaryLabelColor).opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: Options — everything a first-timer shouldn't have to see

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
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
            Button {
                chooseDest()
            } label: {
                Label("Add another destination", systemImage: "plus")
            }
            .font(.callout)
            .help("Copy to several drives in one pass, each independently verified")
            if !destParentPaths.isEmpty {
                Toggle("Save destination as preset", isOn: $saveAsPreset)
                    .help("Reuse it later from the drop prompt and Home")
            }
        }
        .padding(.top, 8)
    }

    // MARK: Pickers

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

    private func chooseDest() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a folder to copy into."
        if panel.runModal() == .OK, let url = panel.url,
           !destParentPaths.contains(url.path) {
            destParentPaths.append(url.path)
        }
    }
}
