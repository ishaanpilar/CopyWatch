import SwiftUI
import AppKit

/// Shown every time files are dropped onto CopyWatch (or sent from the Finder
/// service). The drop never copies straight to a default — the user always
/// confirms here: pick a saved destination, or browse for a new folder.
struct DropDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let sources: [String]

    private var summary: String {
        sources.count == 1
            ? (sources[0] as NSString).lastPathComponent
            : "\(sources.count) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where should this go?").font(.headline)
                    Text("Copying \(summary)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !appState.destinationPresets.isEmpty {
                Text("Saved destinations").font(.caption.bold()).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(appState.destinationPresets) { preset in
                        Button {
                            appState.startCopy(sources, toFolders: preset.allPaths, label: preset.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: preset.isMulti ? "square.stack.3d.up.fill" : "externaldrive.fill")
                                    .foregroundStyle(preset.isDefault ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(preset.name).font(.callout.bold())
                                        if preset.isMulti {
                                            Text("\(preset.allPaths.count) DRIVES")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                        if preset.isDefault {
                                            Text("DEFAULT")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    Text(preset.isMulti
                                         ? preset.allPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                                         : preset.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color(.quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("You haven't saved any destinations yet. Choose a folder below — you can save destinations from the Destinations tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button {
                    browseAndCopy()
                } label: {
                    Label("Choose a Different Folder", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func browseAndCopy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose or create a folder to copy the dropped items into."
        if panel.runModal() == .OK, let url = panel.url {
            appState.startCopy(sources, toFolders: [url.path])
            dismiss()
        }
    }
}
