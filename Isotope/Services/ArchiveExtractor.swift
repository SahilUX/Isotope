import Foundation
import IsotopeCore

/// Unpacking the one archive the catalog has to deal with: Memtest86+ ships
/// `mt86plus_<version>_x86_64.iso.zip` and publishes no raw ISO.
///
/// Foundation has no unzip API, so this shells out to `/usr/bin/ditto`, which is
/// present on every macOS install and — unlike `NSTask` on a helper we would
/// have to bundle — is allowed by the App Sandbox because it is a plain
/// child process reading and writing inside our own container.
protocol ArchiveExtracting: Sendable {
    /// Unpacks `archive` and returns the single `.iso` inside `destination`.
    func extractISO(from archive: URL, into destination: URL) throws -> URL
}

enum ArchiveExtractionError: LocalizedError, Equatable {
    case toolUnavailable
    case toolFailed(status: Int32, message: String)
    case noISOInArchive(String)

    var errorDescription: String? {
        switch self {
        case .toolUnavailable:
            return "This ISO is distributed as a .zip and macOS's unzip tool could not be run, so Isotope cannot unpack it. Download and place it manually."
        case .toolFailed(let status, let message):
            let detail = message.isEmpty ? "exit code \(status)" : message
            return "The downloaded archive could not be unpacked (\(detail)). The file may be corrupted — try again."
        case .noISOInArchive(let name):
            return "“\(name)” did not contain an .iso file. The source may have changed its packaging."
        }
    }
}

struct DittoArchiveExtractor: ArchiveExtracting {
    /// `-x -k` = extract a PKZip archive. Output goes into a directory we own.
    static let toolPath = "/usr/bin/ditto"

    func extractISO(from archive: URL, into destination: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath) else {
            throw ArchiveExtractionError.toolUnavailable
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            // Sandbox denial or a missing tool both land here; either way the
            // user gets the manual-placement advice rather than a crash.
            throw ArchiveExtractionError.toolUnavailable
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ArchiveExtractionError.toolFailed(status: process.terminationStatus, message: message)
        }
        guard let iso = try Self.firstISO(in: destination) else {
            throw ArchiveExtractionError.noISOInArchive(archive.lastPathComponent)
        }
        return iso
    }

    /// Archives sometimes wrap the ISO in a folder, so this walks the tree and
    /// takes the largest `.iso` (guarding against stray sidecar files).
    static func firstISO(in directory: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
        var best: (url: URL, size: Int64)?
        while let url = enumerator?.nextObject() as? URL {
            guard DownloadArtifact.isISO(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if best == nil || size > best!.size { best = (url, size) }
        }
        return best?.url
    }
}
