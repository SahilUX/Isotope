import Foundation
import IsotopeCore

/// A reference to a user-owned file. Importing never moves it into the cache.
struct LocalFile: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String { url.lastPathComponent }
    var id: URL { url }
    var sizeBytes: Int64
    var canFlash: Bool { sizeBytes > 0 && ["iso", "img"].contains(url.pathExtension.lowercased()) }

    init(url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true,
              let size = values.fileSize, FileManager.default.isReadableFile(atPath: url.path) else {
            throw LocalFileError.unreadable
        }
        self.url = url.standardizedFileURL
        self.sizeBytes = Int64(size)
    }

    var release: Release {
        Release(version: .semantic([], raw: "Local file"), fileName: name, sizeBytes: sizeBytes)
    }

    static func isInside(_ source: URL, volume: URL) -> Bool {
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        let root = volume.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

enum LocalFileError: LocalizedError {
    case unreadable
    case unavailableDrive
    case sourceOnDestination
    case busy

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The selected file cannot be read. Choose a regular file you can open."
        case .unavailableDrive: return "The USB drive is no longer available. Reconnect it and try again."
        case .sourceOnDestination: return "The image is on the USB device being erased. Move it to your Mac first."
        case .busy: return "This drive has a transfer in progress. Wait for it to finish."
        }
    }
}
