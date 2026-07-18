import Foundation

/// Project lifecycle, health, stats, timeline, and Smart Import.
/// Everything displayed about a project is derived from its jobs plus the
/// small persisted `Project` record, so nothing here can drift out of sync.
extension AppState {

    // MARK: Lifecycle

    /// Create a project: one folder per destination drive, template folders
    /// inside each, and a saved record. Returns the new project's ID.
    @discardableResult
    func createProject(
        name: String, template: ProjectTemplate,
        customFolders: [String], destParentPaths: [String]
    ) -> UUID? {
        let cleanName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !cleanName.isEmpty, !destParentPaths.isEmpty else { return nil }

        let folders = template == .custom
            ? customFolders.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : template.folders

        let fm = FileManager.default
        var roots: [JobDestination] = []
        for parent in destParentPaths {
            let rootPath = (parent as NSString).appendingPathComponent(cleanName)
            do {
                try fm.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
                for folder in folders {
                    try fm.createDirectory(
                        atPath: (rootPath as NSString).appendingPathComponent(folder),
                        withIntermediateDirectories: true)
                }
            } catch {
                continue   // an unwritable drive is skipped, not fatal
            }
            roots.append(JobDestination(volume: .forPath(rootPath), path: rootPath))
        }
        guard !roots.isEmpty else { return nil }

        var project = Project(id: UUID(), name: cleanName)
        project.templateName = template == .custom ? nil : template.rawValue
        project.roots = roots
        project.folderNames = folders
        project.events = [ProjectEvent(
            kind: .created,
            detail: roots.count > 1
                ? "Project created on \(roots.count) drives"
                : "Project created on \(roots[0].volume.name)")]
        projects.insert(project, at: 0)
        store.save(project)
        return project.id
    }

    /// Remove the project record. Its files and job history stay — jobs are
    /// just unlinked so nothing on any drive is ever touched by a delete.
    func deleteProject(_ projectID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[idx]
        for i in jobs.indices where jobs[i].projectID == projectID {
            jobs[i].projectID = nil
            store.save(jobs[i], force: true)
        }
        store.delete(project)
        projects.remove(at: idx)
    }

    // MARK: Timeline

    func addProjectEvent(_ projectID: UUID, kind: ProjectEventKind, detail: String, jobID: UUID? = nil) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].events.append(ProjectEvent(kind: kind, detail: detail, jobID: jobID))
        store.save(projects[idx])
    }

    // MARK: Derived state

    func jobs(in projectID: UUID) -> [CopyJob] {
        jobs.filter { $0.projectID == projectID }
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Overall health, derived live from the project's jobs.
    func health(of project: Project) -> ProjectHealth {
        let pjobs = jobs(in: project.id).filter { $0.status != .cancelled }
        if pjobs.isEmpty { return .empty }

        if pjobs.contains(where: {
            [.running, .scanning, .queued, .ready].contains($0.status)
        }) { return .backingUp }

        if let stuck = pjobs.first(where: {
            [.completedWithErrors, .interrupted, .waitingForVolume, .paused].contains($0.status)
        }) {
            let what = stuck.sourceLabel ?? stuck.name
            switch stuck.status {
            case .completedWithErrors:
                return .needsAttention("\(stuck.failedFiles) file(s) failed in \(what)")
            case .waitingForVolume:
                return .needsAttention("\(what) is waiting for a drive")
            default:
                return .needsAttention("\(what) didn't finish — resume it")
            }
        }

        // Everything completed. Protected only if every import was hash-verified.
        return pjobs.allSatisfy { $0.verifyAfterCopy } ? .protected : .backedUp
    }

    /// Dashboard stats: (bytes backed up, import count, last activity).
    func stats(of project: Project) -> (bytes: Int64, imports: Int, lastActivity: Date) {
        let pjobs = jobs(in: project.id).filter { $0.status != .cancelled }
        let bytes = pjobs.reduce(Int64(0)) { $0 + $1.doneBytes }
        let jobDates = pjobs.map { $0.completedAt ?? $0.createdAt }
        let last = max(project.events.last?.date ?? project.createdAt, jobDates.max() ?? .distantPast)
        return (bytes, pjobs.count, last)
    }

    /// Per-destination view: is the drive here now, and how many of the
    /// project's imports reached it verified?
    func destinationStatus(of project: Project) -> [(root: JobDestination, connected: Bool, verified: Int, total: Int)] {
        let done = jobs(in: project.id).filter { $0.status == .completed }
        return project.roots.map { root in
            let connected = root.volume.resolve(root.path) != nil
            let landed = done.filter { job in
                job.allDestinations.contains { $0.path.hasPrefix(root.path) }
                    || job.destPath.hasPrefix(root.path)
            }
            let verified = landed.filter { $0.verifyAfterCopy && $0.failedFiles == 0 }.count
            return (root, connected, verified, landed.count)
        }
    }

    // MARK: Import

    /// Copy media (a card volume, or folders picked by hand) into a project
    /// folder on every connected project drive, as one verified job.
    @discardableResult
    func importIntoProject(
        _ projectID: UUID, sourcePaths: [String], folder: String, label: String,
        verify: Bool, algorithm: ChecksumAlgorithm = .sha256
    ) -> UUID? {
        guard let project = project(projectID), !sourcePaths.isEmpty else { return nil }

        var parents: [String] = []
        for root in project.roots {
            guard let resolved = root.volume.resolve(root.path) else { continue }
            let dest = folder.isEmpty
                ? resolved
                : (resolved as NSString).appendingPathComponent(folder)
            try? FileManager.default.createDirectory(
                atPath: dest, withIntermediateDirectories: true)
            parents.append(dest)
        }
        guard !parents.isEmpty else { return nil }

        // Remember a manually-typed folder so future suggestions offer it.
        if let idx = projects.firstIndex(where: { $0.id == projectID }),
           !folder.isEmpty, !projects[idx].folderNames.contains(folder) {
            projects[idx].folderNames.append(folder)
            store.save(projects[idx])
        }

        let jobID = createJob(
            sourcePaths: sourcePaths, destParentPaths: parents,
            verify: verify, algorithm: algorithm,
            projectContext: (projectID, label, folder))
        if let jobID {
            let from = (sourcePaths[0] as NSString).lastPathComponent
            addProjectEvent(projectID, kind: .imported,
                detail: "Imported \(label) from \(from)", jobID: jobID)
        }
        return jobID
    }

    /// Re-check every finished import against the drives as they are now.
    func verifyProject(_ projectID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let candidates = jobs(in: projectID).filter {
            $0.status == .completed || $0.status == .completedWithErrors || $0.status == .interrupted
        }
        guard !candidates.isEmpty else { return }
        for job in candidates { recheck(job.id) }
        projects[idx].lastVerifiedAt = Date()
        projects[idx].events.append(ProjectEvent(
            kind: .reverified,
            detail: "Re-verified \(candidates.count) import(s) against the drives"))
        store.save(projects[idx])
    }

    // MARK: Smart Import (card mount hook)

    /// Called on every volume mount: if it looks like a camera/drone/audio
    /// card and there's a project to file it into, raise the import prompt.
    func cardMounted(_ volume: MountedVolume) {
        guard !projects.isEmpty,
              volume.isEjectable, !volume.isInternal,
              !promptedCardVolumes.contains(volume.path),
              // A project destination drive is never itself a card.
              !projects.contains(where: { p in p.roots.contains { $0.volume.uuid == volume.uuid } }),
              let card = CardDetector.detect(volumePath: volume.path, volumeName: volume.name)
        else { return }
        promptedCardVolumes.insert(volume.path)
        pendingCardImport = card
    }
}
