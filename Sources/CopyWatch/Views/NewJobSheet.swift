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
        VStack(alignment: .leading, spacing: 14) {
            Text("New Copy Job").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("From").gridColumnAlignment(.trailing)
                    TextField("Camera card or folder", text: $sourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { choose(into: $sourcePath) }
                }
                GridRow {
                    Text("To")
                    TextField("Backup folder", text: $destParentPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { choose(into: $destParentPath) }
                }
            }

            if let preview = destPreview {
                Text("Creates \(preview)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Toggle("Verify after copy", isOn: $verify)
                    .help("Reads every copied file back and confirms its checksum matches the source")
                Spacer()
                ForEach(appState.devices) { device in
                    Button("Back up “\(device.name)” instead…") {
                        dismiss()
                        onPickDevice?(device.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("iPhones and cameras aren't disks — they have their own backup flow")
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
        .padding(18)
        .frame(width: 470)
    }

    private func choose(into path: Binding<String>) {
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
