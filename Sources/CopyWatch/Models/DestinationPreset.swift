import Foundation

/// A saved "copy to here" location — drag a source onto this preset (or drop
/// anywhere in the app while it's the default) and CopyWatch starts copying
/// without asking where to put it, the way ShotPut Pro's destination presets work.
struct DestinationPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Primary destination folder.
    var path: String
    /// Extra folders — a multi-destination preset copies one source to all of
    /// these in a single pass. Empty for a normal single-folder preset, so old
    /// saved presets decode unchanged.
    var extraPaths: [String] = []
    var isDefault: Bool = false

    /// All folders in order, primary first.
    var allPaths: [String] { [path] + extraPaths }
    var isMulti: Bool { !extraPaths.isEmpty }
}
