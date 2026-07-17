import Foundation

/// Turns a raw copy/verify failure into a plain-language diagnosis plus a
/// concrete fix, instead of a bare "Failed". Used by the engine when a file
/// or a whole job errors out.
struct CopyDiagnosis: Sendable {
    let title: String     // what went wrong, in human terms
    let fix: String       // what to do about it
    let icon: String      // SF Symbol
    /// True when the problem is with the destination as a whole (out of space,
    /// read-only) so every remaining file would fail too. The engine stops the
    /// transfer in a resumable state instead of churning the rest into failures,
    /// letting the user free space and Try Again, or switch to another drive.
    var haltsTransfer: Bool = false

    /// Classify an error thrown while operating on `path` (for context in a few
    /// cases). `volumeVanished` lets the caller flag a disconnect it already
    /// detected out-of-band (the errno alone can be ambiguous).
    static func diagnose(_ error: Error, path: String? = nil, volumeVanished: Bool = false) -> CopyDiagnosis {
        if volumeVanished {
            return .init(
                title: "Drive disconnected",
                fix: "A drive was unplugged or went to sleep mid-copy. Reconnect it (same or any port) and press Resume — nothing already copied is lost.",
                icon: "externaldrive.badge.xmark")
        }

        let ns = error as NSError
        let posix = posixCode(from: ns)

        switch posix {
        case ENOSPC, EDQUOT:
            return .init(
                title: "Destination is full",
                fix: "The destination drive ran out of space. Free some up and press Resume, or use Change Destination to finish the backup on a larger drive. Nothing already copied is lost.",
                icon: "internaldrive.badge.exclamationmark",
                haltsTransfer: true)
        case EACCES, EPERM:
            return .init(
                title: "Permission denied",
                fix: "macOS blocked access to this location. Grant CopyWatch Full Disk Access in System Settings → Privacy & Security, or pick a folder you own (e.g. inside your home or an external drive).",
                icon: "lock.trianglebadge.exclamationmark")
        case EROFS:
            return .init(
                title: "Destination is read-only",
                fix: "The destination became read-only — often an NTFS/Windows-formatted drive, or one mounted read-only. Remount it with write access and press Resume, or use Change Destination to finish on a Mac-formatted (APFS/ExFAT) drive.",
                icon: "pencil.slash",
                haltsTransfer: true)
        case ENAMETOOLONG:
            return .init(
                title: "Name too long for the destination",
                fix: "A file or folder name exceeds what the destination's format allows. Shorten the name, or use an APFS/ExFAT drive which allows longer names.",
                icon: "textformat.abc.dottedunderline")
        case EIO:
            return .init(
                title: "USB connection unstable",
                fix: "A read/write error usually means a flaky cable, hub, or port. Try a different cable, plug directly into the Mac (skip hubs), then Resume.",
                icon: "cable.connector.slash")
        case ENXIO, ENODEV, ENOENT:
            return .init(
                title: "Drive or file went missing",
                fix: "The drive or a file is no longer reachable. Reconnect the drive and press Resume; if the source file was deleted, that item can't be copied.",
                icon: "externaldrive.badge.questionmark")
        case ETIMEDOUT:
            return .init(
                title: "Drive stopped responding",
                fix: "The drive timed out — it may be failing or asleep. Reconnect it (ideally a different cable/port) and Resume. If it keeps happening, run a Transfer Benchmark to check the drive's health.",
                icon: "clock.badge.exclamationmark")
        default:
            break
        }

        // CocoaError fallbacks (Foundation sometimes wraps the errno).
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                return diagnose(makePOSIX(ENOSPC))
            case .fileWriteVolumeReadOnly:
                return diagnose(makePOSIX(EROFS))
            case .fileWriteNoPermission, .fileReadNoPermission:
                return diagnose(makePOSIX(EACCES))
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return diagnose(makePOSIX(ENOENT))
            default:
                break
            }
        }

        return .init(
            title: "Copy failed",
            fix: "\(error.localizedDescription) Try Resume; if it repeats, check the cable and that both drives have space and write access.",
            icon: "exclamationmark.triangle")
    }

    private static func posixCode(from ns: NSError) -> Int32? {
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        // A CocoaError often carries the real errno as an underlying error.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }

    private static func makePOSIX(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
