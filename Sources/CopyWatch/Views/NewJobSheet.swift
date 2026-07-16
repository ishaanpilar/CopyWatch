import SwiftUI
import AppKit

struct NewJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let onCreate: (String, String, Bool) -> Void
    var onPickDevice: ((String) -> Void)?

    @State private var sourcePath = ""
    @State private var destParentPath = ""
    @State private var verify = true

    private var destPreview: String? {
        guard !sourcePath.isEmpty, !destParentPath.isEmpty else { return nil }
        return (destParentPath as NSString)
            .appendingPathComponent((sourcePath as NSString).lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Copy Job").font(.title3.bold())

            pathPicker(
                label: "Copy from",
                hint: "Camera card, SSD folder…",
                path: $sourcePath)

            // iPhones/cameras never appear in the folder picker — they aren't
            // disks. Route to their catalog-based backup flow instead.
            if appState.devices.isEmpty {
                Text("Looking for an iPhone or camera? It won't appear in the folder picker (it's not a disk). Plug it in and it shows up under Devices in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.devices) { device in
                        Button {
                            dismiss()
                            onPickDevice?(device.id)
                        } label: {
                            Label("Backing up “\(device.name)”? Use the device flow — pick its folders & files there", systemImage: "iphone")
                        }
                        .buttonStyle(.link)
                    }
                    Text("iPhones aren't disks, so they can't be chosen as a folder above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            pathPicker(
                label: "Copy into",
                hint: "Backup drive folder…",
                path: $destParentPath)

            if let preview = destPreview {
                Label {
                    Text("Files will land in ") +
                    Text(preview).font(.caption.monospaced()).bold()
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle(isOn: $verify) {
                VStack(alignment: .leading) {
                    Text("Verify after copy")
                    Text("Reads every copied file back and confirms its checksum matches the source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Copy") {
                    onCreate(sourcePath, destParentPath, verify)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sourcePath.isEmpty || destParentPath.isEmpty || sourcePath == destParentPath)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pathPicker(label: String, hint: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            HStack {
                TextField(hint, text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select"
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
            }
        }
    }
}
