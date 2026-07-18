import Foundation

/// Recognizes a freshly mounted volume as a camera card / drone card / audio
/// recorder by its on-disk folder structure (DCIM, PRIVATE/M4ROOT, AVCHD,
/// DJI…) — not by volume name, which users rename. Powers Smart Import: when a
/// known card appears, CopyWatch offers to file it into the right project
/// folder in one click.
enum CardDetector {

    enum Kind: Equatable {
        case camera(brand: String?)   // generic DCIM card; brand from DCIM subfolders
        case drone(brand: String)
        case gopro
        case audioRecorder
        case avchdCamcorder

        /// Short human label: "Sony camera card", "DJI drone card"…
        var label: String {
            switch self {
            case .camera(let brand): brand.map { "\($0) camera card" } ?? "Camera card"
            case .drone(let brand): "\(brand) drone card"
            case .gopro: "GoPro card"
            case .audioRecorder: "Audio recorder card"
            case .avchdCamcorder: "AVCHD camcorder card"
            }
        }

        var icon: String {
            switch self {
            case .camera: "camera"
            case .drone: "airplane"
            case .gopro: "video"
            case .audioRecorder: "waveform"
            case .avchdCamcorder: "video"
            }
        }

        /// Named-folder keywords tried first; when none match, camera-style
        /// cards fall through to the "Card N" series instead.
        var folderKeywords: [String] {
            switch self {
            case .drone: ["drone"]
            case .gopro: ["gopro"]
            case .audioRecorder: ["audio", "sound", "recording"]
            case .camera, .avchdCamcorder: []
            }
        }
    }

    struct DetectedCard: Identifiable, Equatable {
        var id: String { volumePath }
        let volumePath: String
        let volumeName: String
        let kind: Kind
    }

    /// Inspect the root of a mounted volume. Returns nil when it doesn't look
    /// like a camera/recorder card (so ordinary drives never trigger a prompt).
    static func detect(volumePath: String, volumeName: String) -> DetectedCard? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: volumePath) else { return nil }
        let upper = Set(entries.map { $0.uppercased() })

        func kind() -> Kind? {
            // DJI drones: a DJI folder at root, or DJI_* clips inside DCIM.
            if upper.contains("DJI") { return .drone(brand: "DJI") }

            if upper.contains("DCIM") {
                let sub = ((try? fm.contentsOfDirectory(atPath: volumePath + "/DCIM")) ?? [])
                    .map { $0.uppercased() }
                if sub.contains(where: { $0.contains("GOPRO") }) { return .gopro }
                // DJI drones name DCIM subfolders DJI_001, 100MEDIA (Mini), etc.
                if sub.contains(where: { $0.contains("DJI") }) { return .drone(brand: "DJI") }
                let brands: [(marker: String, name: String)] = [
                    ("MSDCF", "Sony"), ("CANON", "Canon"), ("NIKON", "Nikon"),
                    ("FUJI", "Fujifilm"), ("OLYMP", "OM System"), ("PANA", "Panasonic"),
                    ("LEICA", "Leica"), ("EOS", "Canon"),
                ]
                for b in brands where sub.contains(where: { $0.contains(b.marker) }) {
                    return .camera(brand: b.name)
                }
                // Sony XAVC cards pair DCIM with PRIVATE/M4ROOT.
                if upper.contains("PRIVATE"),
                   ((try? fm.contentsOfDirectory(atPath: volumePath + "/PRIVATE")) ?? [])
                    .map({ $0.uppercased() }).contains("M4ROOT") {
                    return .camera(brand: "Sony")
                }
                return .camera(brand: nil)
            }

            // Sony XAVC without a DCIM (video-only formats).
            if upper.contains("PRIVATE") {
                let priv = ((try? fm.contentsOfDirectory(atPath: volumePath + "/PRIVATE")) ?? [])
                    .map { $0.uppercased() }
                if priv.contains("M4ROOT") { return .camera(brand: "Sony") }
                if priv.contains("AVCHD") { return .avchdCamcorder }
            }
            if upper.contains("AVCHD") { return .avchdCamcorder }

            // Field recorders (Zoom, Tascam) put numbered WAV folders at root.
            let recorderMarkers = ["ZOOM", "TASCAM", "MULTITRACK", "STEREO", "SOUND"]
            if recorderMarkers.contains(where: { m in upper.contains(where: { $0.contains(m) }) }) {
                return .audioRecorder
            }
            return nil
        }

        guard let k = kind() else { return nil }
        return DetectedCard(volumePath: volumePath, volumeName: volumeName, kind: k)
    }

    // MARK: Suggestions

    /// Pick the project this card most likely belongs to: the one most
    /// recently worked on (latest event or job activity).
    static func suggestProject(from projects: [Project], jobs: [CopyJob]) -> Project? {
        func lastActivity(_ p: Project) -> Date {
            let eventDate = p.events.last?.date ?? p.createdAt
            let jobDate = jobs.filter { $0.projectID == p.id }
                .map { $0.completedAt ?? $0.createdAt }.max() ?? .distantPast
            return max(eventDate, jobDate)
        }
        return projects.max { lastActivity($0) < lastActivity($1) }
    }

    /// Suggest a folder within the project for this card. Drone cards land in
    /// the Drone folder; camera cards get the next free "Card N"; otherwise the
    /// first keyword match, falling back to the first folder or the root.
    static func suggestFolder(for kind: Kind, in project: Project, jobs: [CopyJob]) -> String {
        let folders = project.folderNames

        // Specific keyword match first ("drone", "audio", "gopro"…).
        for keyword in kind.folderKeywords {
            if let hit = folders.first(where: { $0.lowercased().contains(keyword) }) {
                return hit
            }
        }

        // Camera-style cards: continue the "Card N" series wherever it lives.
        if let cardFolder = folders.first(where: { $0.lowercased().contains("card") }) {
            let parent = (cardFolder as NSString).deletingLastPathComponent
            let next = (usedCardNumbers(in: project, jobs: jobs).max() ?? 0) + 1
            let name = "Card \(next)"
            return parent.isEmpty ? name : "\(parent)/\(name)"
        }
        return folders.first ?? ""
    }

    /// Card numbers already used by this project's jobs ("… Card 3" labels)
    /// so the next import continues the series even if the drive is offline.
    private static func usedCardNumbers(in project: Project, jobs: [CopyJob]) -> [Int] {
        let labels = jobs.filter { $0.projectID == project.id }
            .compactMap { $0.sourceLabel ?? $0.projectFolder }
        var numbers: [Int] = []
        for label in labels {
            let scanner = Foundation.Scanner(string: label)
            _ = scanner.scanUpToString("Card ")
            if scanner.scanString("Card ") != nil, let n = scanner.scanInt() {
                numbers.append(n)
            }
        }
        // Also count template folders like "01_Footage/Card 1".
        for f in project.folderNames {
            let scanner = Foundation.Scanner(string: f)
            _ = scanner.scanUpToString("Card ")
            if scanner.scanString("Card ") != nil, let n = scanner.scanInt() {
                numbers.append(n)
            }
        }
        return numbers
    }
}
