import SwiftUI
import AppKit

struct NewJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let onCreate: ([String], String, Bool) -> Void
    var onPickDevice: ((String) -> Void)?

    @State private var sourcePaths: [String]
    @State private var destParentPath: String
    @State private var verify = true
    @State private var saveAsDefaultDestination = false

    init(initialSources: [String] = [], initialDest: String = "",
         onCreate: @escaping ([String], String, Bool) -> Void,
         onPickDevice: ((String) -> Void)? = nil) {
        self.onCreate = onCreate
        self.onPickDevice = onPickDevice
        _sourcePaths = State(initialValue: initialSources)
        _destParentPath = State(initialValue: initialDest)
    }

    private var sourceSummary: String {
        switch sourcePaths.count {
        case 0: ""
        case 1: sourcePaths[0]
        default: "\(sourcePaths.count) items selected"
        }
    }

    private var destPreview: String? {
        guard !sourcePaths.isEmpty, !destParentPath.isEmpty else { return nil }
        let name = sourcePaths.count == 1
            ? (sourcePaths[0] as NSString).lastPathComponent
            : "Selected Files"
        return (destParentPath as NSString).appendingPathComponent(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Copy Job").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("From").gridColumnAlignment(.trailing)
                    TextField("Camera card, folder, or files", text: .constant(sourceSummary))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose") { chooseSource() }
                }
                GridRow {
                    Text("To")
                    TextField("Backup folder", text: $destParentPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose") { chooseDest() }
                }
            }

            if let preview = destPreview {
                Text("Creates \(preview)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle("Verify after copy", isOn: $verify)
                .help("Reads every copied file back and confirms its checksum matches the source")

            if !destParentPath.isEmpty {
                Toggle("Remember this as my default destination", isOn: $saveAsDefaultDestination)
                    .help("Next time, dropping files onto CopyWatch copies straight here — no prompt")
            }

            HStack {
                Spacer()
                ForEach(appState.devices) { device in
                    Button("Back up “\(device.name)” instead") {
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
                    if saveAsDefaultDestination {
                        appState.addDestinationPreset(
                            name: (destParentPath as NSString).lastPathComponent,
                            path: destParentPath)
                        appState.setDefaultDestination(appState.destinationPresets.last!.id)
                    }
                    onCreate(sourcePaths, destParentPath, verify)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sourcePaths.isEmpty || destParentPath.isEmpty
                          || sourcePaths.contains(destParentPath))
            }
        }
        .padding(18)
        .frame(width: 470)
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

    private func chooseDest() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose or create a folder to copy into."
        if panel.runModal() == .OK, let url = panel.url {
            destParentPath = url.path
        }
    }
}
