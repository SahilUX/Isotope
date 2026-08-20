import Foundation
import IsotopeCore

/// A volume resolved from a stored bookmark, plus a rewritten bookmark when
/// macOS reported the old one stale (the caller re-persists it).
struct ResolvedVolume: Sendable {
    var url: URL
    var refreshedBookmark: Data?
}

/// The writing half of drive access, kept behind a protocol so `UpdateEngine`
/// can be driven against a temporary directory in tests — the copy itself still
/// runs for real, only the bookmark/volume metadata is faked (DESIGN §7).
protocol DriveWriting: Sendable {
    /// Resolves the bookmark, refreshing it when stale (`isStale` from
    /// `DriveAccess.resolveBookmark`).
    func resolveVolume(bookmark: Data) throws -> ResolvedVolume
    func volumeInfo(at url: URL) throws -> VolumeInfo
    /// Security scope must be held for the whole copy, so begin/end are separate.
    func beginAccess(_ url: URL) -> Bool
    func endAccess(_ url: URL)
}

struct LiveDriveWriter: DriveWriting {
    func resolveVolume(bookmark: Data) throws -> ResolvedVolume {
        let resolved = try DriveAccess.resolveBookmark(bookmark)
        guard resolved.isStale else { return ResolvedVolume(url: resolved.url) }
        // A stale bookmark still resolves; rewriting it now avoids losing access
        // after the next OS update or volume rename.
        let refreshed = try? DriveAccess.withAccess(to: resolved.url) { url in
            try DriveAccess.makeBookmark(for: url)
        }
        return ResolvedVolume(url: resolved.url, refreshedBookmark: refreshed)
    }

    func volumeInfo(at url: URL) throws -> VolumeInfo {
        try DriveAccess.volumeInfo(at: url)
    }

    func beginAccess(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }

    func endAccess(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
