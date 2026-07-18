import Foundation
import SwiftUI

/// A production: "BMW Commercial", "Wedding — Sarah & John". The organizing
/// unit the app revolves around. A project owns one folder per destination
/// drive (its roots), a chronological event history, and — via `projectID` on
/// `CopyJob` — every copy made for it. Everything else shown in the UI
/// (health, size, card records) is derived live from those jobs, so the
/// project record can never drift out of sync with what actually happened.
struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date = Date()
    /// Raw `ProjectTemplate` name this was created from (display only).
    var templateName: String?
    /// The project's folder on each destination drive, e.g.
    /// /Volumes/T9/BMW Commercial. First is primary; extras are mirrors.
    var roots: [JobDestination] = []
    /// Chronological history, oldest first. Appended, never rewritten.
    var events: [ProjectEvent] = []
    /// When "Verify Project" last re-checked every job.
    var lastVerifiedAt: Date?

    /// Folder names (relative to a root) offered by Smart Import — the
    /// template's folders as created, so suggestions match the real structure.
    var folderNames: [String] = []
}

/// One entry in a project's timeline.
struct ProjectEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let kind: ProjectEventKind
    /// Human line: "Sony FX3 Card 1 — 843 files, 128 GB".
    let detail: String
    var jobID: UUID?

    init(kind: ProjectEventKind, detail: String, jobID: UUID? = nil, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.detail = detail
        self.jobID = jobID
    }
}

enum ProjectEventKind: String, Codable {
    case created, imported, backedUp, verified, issue, reverified, freedSource, destinationAdded

    var icon: String {
        switch self {
        case .created: "folder.badge.plus"
        case .imported: "square.and.arrow.down"
        case .backedUp: "externaldrive.badge.checkmark"
        case .verified: "checkmark.seal"
        case .issue: "exclamationmark.triangle"
        case .reverified: "arrow.triangle.2.circlepath"
        case .freedSource: "trash"
        case .destinationAdded: "externaldrive.badge.plus"
        }
    }

    var tint: Color {
        switch self {
        case .verified, .backedUp: .green
        case .issue: .orange
        case .freedSource: .secondary
        default: .accentColor
        }
    }
}

/// Derived overall status shown on the dashboard. Never persisted.
enum ProjectHealth {
    case empty            // no media imported yet
    case backingUp        // a copy is running or queued
    case protected        // every job complete and hash-verified
    case backedUp         // complete, but some copies weren't verified
    case needsAttention(String)   // something demands action

    var label: String {
        switch self {
        case .empty: "No media yet"
        case .backingUp: "Backing up…"
        case .protected: "Protected"
        case .backedUp: "Backed up"
        case .needsAttention: "Needs attention"
        }
    }

    var detail: String? {
        if case .needsAttention(let why) = self { return why }
        return nil
    }

    var icon: String {
        switch self {
        case .empty: "circle.dashed"
        case .backingUp: "arrow.triangle.2.circlepath"
        case .protected: "checkmark.seal.fill"
        case .backedUp: "checkmark.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .empty: .secondary
        case .backingUp: .blue
        case .protected: .green
        case .backedUp: .green
        case .needsAttention: .orange
        }
    }
}

/// Folder-structure starting points. Deliberately generic — the same
/// offload-and-verify workflow belongs to photographers, podcasters, drone
/// pilots, agencies, and researchers as much as filmmakers. Templates only
/// create folders; the user stays free to reorganize afterwards.
enum ProjectTemplate: String, CaseIterable, Identifiable {
    case media = "Media Production"
    case photography = "Photography"
    case eventCoverage = "Event Coverage"
    case audio = "Audio & Podcast"
    case clientWork = "Client Work"
    case research = "Data & Research"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .media: "film"
        case .photography: "camera"
        case .eventCoverage: "calendar"
        case .audio: "waveform"
        case .clientWork: "briefcase"
        case .research: "tray.full"
        case .custom: "square.dashed.inset.filled"
        }
    }

    /// Who this is for — shown alongside the name in the template picker.
    var subtitle: String {
        switch self {
        case .media: "Film, video, YouTube"
        case .photography: "Shoots, sessions, archives"
        case .eventCoverage: "Weddings, conferences, sports"
        case .audio: "Field recordings, episodes"
        case .clientWork: "Agencies, freelancers"
        case .research: "Instruments, surveys, batches"
        case .custom: "Your own structure"
        }
    }

    /// Relative folders to create under each project root.
    var folders: [String] {
        switch self {
        case .media: [
            "Footage/Card 1",
            "Footage/Drone",
            "Audio",
            "Music",
            "Graphics",
            "Project Files",
            "Deliverables",
        ]
        case .photography: [
            "Cards/Card 1",
            "Selects",
            "Edited",
            "Exports",
        ]
        case .eventCoverage: [
            "Cards/Card 1",
            "Drone",
            "Audio",
            "Photos",
            "Exports",
        ]
        case .audio: [
            "Recordings/Session 1",
            "Music & SFX",
            "Edits",
            "Exports",
        ]
        case .clientWork: [
            "Received",
            "Assets",
            "Work Files",
            "Deliverables",
            "Archive",
        ]
        case .research: [
            "Raw Data/Batch 1",
            "Processed",
            "Documents",
            "Reports",
        ]
        case .custom: []
        }
    }
}
