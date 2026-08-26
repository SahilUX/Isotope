import AppKit
import Foundation
import IsotopeCore

/// What a mounted volume looks like to Isotope (DESIGN §4.3).
struct VolumeInfo: Sendable, Equatable {
    var url: URL
    /// Nil for volumes that publish no UUID (some network/disk-image mounts).
    var volumeUUID: String?
    var name: String
    var capacityBytes: Int64?
    /// `volumeAvailableCapacityForImportantUsage` — what a copy can actually use.
    var availableBytes: Int64?
    var isReadOnly: Bool
    var isRemovable: Bool
}

enum DriveAccessError: LocalizedError, Equatable {
    case noVolumeUUID(String)
    case ejectFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVolumeUUID(let name):
            return "“\(name)” does not report a volume UUID, so Isotope cannot recognise it again after it is unplugged."
        case .ejectFailed(let message):
            return "The drive could not be ejected: \(message)"
        }
    }
}

/// Security-scoped bookmarks, volume metadata and ISO-folder listing (DESIGN §4.3).
///
/// Everything here is a static function over a URL: no state, so the pieces that
/// do not need a real volume (`isoFolderURL`) are directly testable, and the
/// pieces that do are injected into `AppStore` through `DriveProbe`.
enum DriveAccess {
    // MARK: - Volume metadata

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeIsReadOnlyKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
    ]

    static func volumeInfo(at url: URL) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: resourceKeys)
        let name = values.volumeName ?? url.lastPathComponent
        // volumeAvailableCapacityForImportantUsage is APFS-aware (purgeable space)
        // but reports 0/nil on FAT/exFAT volumes — i.e. every Ventoy stick.
        let importantUsage = values.volumeAvailableCapacityForImportantUsage
        let available = (importantUsage.map { $0 > 0 } == true)
            ? importantUsage
            : values.volumeAvailableCapacity.map(Int64.init)
        return VolumeInfo(url: url,
                          volumeUUID: values.volumeUUIDString,
                          name: name,
                          capacityBytes: values.volumeTotalCapacity.map(Int64.init),
                          availableBytes: available,
                          isReadOnly: values.volumeIsReadOnly ?? false,
                          isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false))
    }

    /// Currently mounted volumes, used for the initial enumeration at launch
    /// (DESIGN §4.3). Reading metadata never needs security scope.
    static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(resourceKeys),
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { try? volumeInfo(at: $0) }
    }

    static func volumeInfo(forVolumeUUID uuid: String) -> VolumeInfo? {
        mountedVolumes().first { $0.volumeUUID == uuid }
    }

    // MARK: - Bookmarks

    /// A security-scoped bookmark for a user-selected volume (PRD F1/N2). The
    /// URL must come from an open panel; the sandbox refuses otherwise.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }

    /// Resolves a stored bookmark. `isStale` means macOS wants the bookmark
    /// rewritten — the caller refreshes it rather than failing.
    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// Runs `body` with the security scope held, always balancing the stop.
    static func withAccess<T>(to url: URL, _ body: (URL) throws -> T) throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    // MARK: - ISO folder

    /// `isoFolder` is a path relative to the volume root; "" (the default) is
    /// the root itself. Leading/trailing slashes and "." are tolerated because
    /// the value is typed by hand in drive settings.
    static func isoFolderURL(volume: URL, isoFolder: String) -> URL {
        let trimmed = isoFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/").map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        return components.reduce(volume) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Filenames (not paths) directly inside the drive's ISO folder. Filtering
    /// down to real ISOs is `DriveScan`'s job so it stays testable in Core.
    static func fileNames(inFolder folder: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(at: folder,
                                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                                   options: [])
        return contents.compactMap { url in
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            return isRegular == false ? nil : url.lastPathComponent
        }
    }

    /// Sizes of the visible ISOs in a folder, by filename. Read from the same
    /// directory enumeration the listing uses, so a scan costs one pass.
    static func isoSizes(inFolder folder: URL) throws -> [String: Int64] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        var sizes: [String: Int64] = [:]
        for url in contents where DriveScan.isISOFileName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile != false, let size = values?.fileSize else { continue }
            sizes[url.lastPathComponent] = Int64(size)
        }
        return sizes
    }

    /// `isoSizes(inFolder:)` with the bookmark's security scope held. A folder
    /// that cannot be read yields no sizes rather than an error: a size is a
    /// nicety, and a scan must never fail over one.
    static func isoSizes(bookmark: Data, isoFolder: String) -> [String: Int64] {
        guard let resolved = try? resolveBookmark(bookmark) else { return [:] }
        return (try? withAccess(to: resolved.url) { volume -> [String: Int64] in
            let folder = isoFolderURL(volume: volume, isoFolder: isoFolder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
            return (try? isoSizes(inFolder: folder)) ?? [:]
        }) ?? [:]
    }

    /// Lists the drive's ISO folder with the bookmark's security scope held.
    /// A missing folder reads as an empty listing: the user may simply not have
    /// created it yet, and a scan must never be destructive or fatal.
    static func isoFileNames(bookmark: Data, isoFolder: String) throws -> [String] {
        let resolved = try resolveBookmark(bookmark)
        return try withAccess(to: resolved.url) { volume in
            let folder = isoFolderURL(volume: volume, isoFolder: isoFolder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return DriveScan.isoFileNames(in: try fileNames(inFolder: folder))
        }
    }

    // MARK: - Eject

    /// PRD F23 one-click eject. `NSWorkspace` handles the unmount so no
    /// privileged helper or DiskArbitration session is needed (DESIGN §1/N3).
    static func eject(volumeURL: URL) throws {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
        } catch {
            throw DriveAccessError.ejectFailed(error.localizedDescription)
        }
    }
}

/// The filesystem reads drive management needs, injectable so the app tests can
/// register and scan drives without a USB stick or an open panel.
struct DriveProbe: Sendable {
    var info: @Sendable (URL) throws -> VolumeInfo
    var bookmark: @Sendable (URL) throws -> Data
    /// (bookmark, isoFolder) → the `.iso` filenames in that folder.
    var listISOs: @Sendable (Data, String) throws -> [String]
    /// (bookmark, isoFolder, fileName) → the build recorded inside that ISO, for
    /// the one kind of media whose filename does not carry it (PRD F43
    /// addendum). Blocking: it mounts the image, so callers run it off the main
    /// actor. Nil for anything that is not Windows media, or will not say.
    /// (bookmark, isoFolder) → each ISO's size on disk, by filename. Separate
    /// from `listISOs` so the existing seam — and every test that uses it —
    /// stays as it was; sizes are display detail, and a probe that cannot read
    /// them simply reports none.
    var isoSizes: @Sendable (Data, String) -> [String: Int64] = { bookmark, folder in
        DriveAccess.isoSizes(bookmark: bookmark, isoFolder: folder)
    }
    var windowsBuild: @Sendable (Data, String, String) -> String? = { bookmark, folder, fileName in
        guard let resolved = try? DriveAccess.resolveBookmark(bookmark) else { return nil }
        return try? DriveAccess.withAccess(to: resolved.url) { volume in
            let file = DriveAccess.isoFolderURL(volume: volume, isoFolder: folder)
                .appendingPathComponent(fileName)
            return WindowsISOInspector().identity(ofISOAt: file)?.build
        }
    }

    static let live = DriveProbe(
        info: { try DriveAccess.volumeInfo(at: $0) },
        bookmark: { try DriveAccess.makeBookmark(for: $0) },
        listISOs: { bookmark, folder in
            try DriveAccess.isoFileNames(bookmark: bookmark, isoFolder: folder)
        })
}
