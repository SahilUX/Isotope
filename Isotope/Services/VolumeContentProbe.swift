import Foundation
import IsotopeCore

/// PRD F44, app side: runs a catalog entry's `ContentProbe` list against the
/// volumes a flashed drive currently has mounted.
///
/// Strictly read-only, and structurally so — the only file API used here is
/// `FileHandle(forReadingFrom:)`, there is no write path to get wrong. No
/// administrator rights, no raw device access: this reads mounted files exactly
/// the way Finder would. Every failure (missing file, unreadable volume, denied
/// by TCC, binary rubbish) is silence, and silence means the caller falls back
/// to the volume label (PRD F40).
enum VolumeContentProbe {
    /// Marker files are tens of bytes. The cap is what makes "read the file at
    /// this path" safe when the path in the catalog turns out to name something
    /// enormous — a wrong probe must cost a few kilobytes, not a gigabyte.
    static let maxReadBytes = 64 * 1024

    /// The first version any probe yields, over the volumes in the order given.
    /// Nil when there is nothing to read or nothing parses.
    static func version(probes: [ContentProbe], volumes: [URL]) -> VersionToken? {
        guard !probes.isEmpty else { return nil }
        for volume in volumes {
            if let version = ContentProbeRunner.version(probes: probes, read: { relativePath in
                readText(at: volume.appendingPathComponent(relativePath))
            }) {
                return version
            }
        }
        return nil
    }

    /// Up to `maxReadBytes` of a file, decoded as UTF-8 (lossily, so a marker
    /// file with a stray byte still parses). Nil for anything that will not open
    /// or does not decode.
    static func readText(at url: URL, limit: Int = maxReadBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
