import SwiftUI
import AppKit

/// In-app About screen (also reachable via CopyWatch menu → About CopyWatch).
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("CopyWatch")
                .font(.largeTitle.bold())
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Created by Ishaan Pilar")
                .font(.title3.weight(.medium))
                .padding(.top, 6)

            Text("Verified, resumable file backups for filmmakers — checksummed copy jobs, interrupted-copy rescue, folder comparison, and iPhone backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/ishaanpilar/CopyWatch")!)
                Link("Report an issue", destination: URL(string: "https://github.com/ishaanpilar/CopyWatch/issues")!)
            }
            .padding(.top, 4)

            Spacer()
            Text("© 2026 Ishaan Pilar")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
