import Foundation

/// A saved "copy to here" location — drag a source onto this preset (or drop
/// anywhere in the app while it's the default) and CopyWatch starts copying
/// without asking where to put it, the way ShotPut Pro's destination presets work.
struct DestinationPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var isDefault: Bool = false
}
