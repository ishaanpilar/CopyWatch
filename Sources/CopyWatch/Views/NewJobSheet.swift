import SwiftUI
import AppKit

struct NewJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String, Bool) -> Void

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
