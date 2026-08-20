import Foundation
import IsotopeCore

/// Reads the exact build out of a Windows ISO (PRD F43 addendum).
///
/// Microsoft's media names carry the feature release and nothing else, and the
/// same `Win11_25H2_English_x64.iso` name is reused when the media is refreshed
/// with a newer build. The build is inside the image, in the XML resource of
/// `sources/install.wim`, so the file has to be opened to answer the question
/// "which 25H2 is this?".
///
/// macOS mounts ISO9660/UDF images read-only with no administrator rights, so
/// this is `hdiutil attach -readonly` plus two `read`s and a detach. It is the
/// platform glue for `WindowsImageReader`, which owns the format knowledge and
/// stays portable; a Linux port replaces the mount, not the parsing.
///
/// Every failure — not a Windows ISO, no `sources` directory, an image that
/// declines to say, a mount that will not attach — returns nil. An unknown
/// build is displayed as unknown; it is never guessed from the filename.
protocol WindowsMediaInspecting: Sendable {
    func identity(ofISOAt url: URL) -> WindowsImageIdentity?
}

struct WindowsISOInspector: WindowsMediaInspecting {
    static let toolPath = "/usr/bin/hdiutil"

    /// Mounting and unmounting a multi-gigabyte image off a USB stick is
    /// seconds of work, not minutes. The cap keeps a wedged mount from holding
    /// a scan open forever.
    static let timeout: TimeInterval = 90

    func identity(ofISOAt url: URL) -> WindowsImageIdentity? {
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath),
              let mount = attach(url) else { return nil }
        defer { detach(mount.devEntry) }
        guard let image = Self.installImageURL(inMountedISO: mount.mountPoint) else { return nil }
        return Self.identity(ofImageAt: image)
    }

    // MARK: - The testable half

    /// The build recorded in an already-reachable `install.wim`/`.esd`/`.swm`.
    ///
    /// Two bounded reads — a 208-byte header, then the XML block it points at —
    /// and no writes. A file that is not a WIM fails the magic check in
    /// `WindowsImageReader` and costs those 208 bytes.
    static func identity(ofImageAt url: URL) -> WindowsImageIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: WindowsImageReader.headerLength),
              let resource = WindowsImageReader.xmlResource(header: header),
              (try? handle.seek(toOffset: resource.offset)) != nil,
              let raw = try? handle.read(upToCount: Int(resource.size)),
              raw.count == Int(resource.size),
              let xml = WindowsImageReader.decodeXML(raw)
        else { return nil }
        return WindowsImageReader.identity(xml: xml)
    }

    /// The install image inside a mounted Windows ISO, matched case-insensitively:
    /// the media is UDF written by Windows tooling, and the case of `sources`
    /// varies between Microsoft's own images.
    static func installImageURL(inMountedISO root: URL) -> URL? {
        guard let sources = child(of: root, named: "sources") else { return nil }
        for name in WindowsImageReader.installImageNames {
            if let image = child(of: sources, named: name) { return image }
        }
        return nil
    }

    private static func child(of directory: URL, named name: String) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Mounting

    private struct Mount {
        let devEntry: String
        let mountPoint: URL
    }

    /// `-nobrowse` keeps the volume out of Finder, `-noverify`/`-noautoopen`
    /// keep a 6 GB mount from checksumming and opening windows, and `-readonly`
    /// is the guarantee that matters: an inspection cannot modify the ISO it is
    /// reading, whatever else goes wrong.
    private func attach(_ url: URL) -> Mount? {
        let output = Self.run(arguments: ["attach", url.path, "-readonly", "-nobrowse",
                                          "-noverify", "-noautoopen", "-plist"])
        guard let output,
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }

        // A hybrid ISO attaches as several entities: the whole device plus its
        // filesystems. The mounted one is the one to read; the device entry —
        // the shortest `/dev/diskN` — is what detaches all of them at once.
        let mountPoint = entities.compactMap { $0["mount-point"] as? String }
            .first { !$0.isEmpty }
        let devEntry = entities.compactMap { $0["dev-entry"] as? String }
            .min { $0.count < $1.count }
        guard let mountPoint, let devEntry else {
            // Attached but not mounted (no filesystem macOS reads): still ours
            // to clean up.
            if let devEntry = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) {
                detach(devEntry)
            }
            return nil
        }
        return Mount(devEntry: devEntry, mountPoint: URL(fileURLWithPath: mountPoint))
    }

    private func detach(_ devEntry: String) {
        _ = Self.run(arguments: ["detach", devEntry, "-force"])
    }

    /// stdout of `hdiutil`, or nil for any non-zero exit, launch failure or
    /// timeout. stderr is dropped: there is no failure here the user needs to
    /// see, because the caller's fallback is "the build is unknown".
    private static func run(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a full pipe buffer would otherwise deadlock the
        // child against a parent that is waiting for it to exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
