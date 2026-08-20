import Foundation

/// Naming rules for the download pipeline: what a downloaded file is called,
/// whether it is an archive that still has to be unpacked, and what key it takes
/// in the cache index. Pure string work so it is testable without a network or
/// a filesystem (DESIGN §7).
public enum DownloadArtifact {
    // MARK: - Kinds

    public static func isZipArchive(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".zip")
    }

    public static func isISO(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".iso")
    }

    /// The ISO hiding inside an archive. Upstream ships Memtest86+ only as
    /// `mt86plus_7.20_x86_64.iso.zip`, so the pipeline has to know the name it
    /// will place on the drive before it unpacks anything.
    ///
    /// `foo.iso.zip` → `foo.iso`; `foo.zip` → `foo.iso`; a non-archive is
    /// returned unchanged.
    public static func isoName(fromArchive name: String) -> String {
        guard isZipArchive(name) else { return name }
        let stem = String(name.dropLast(4))
        return isISO(stem) ? stem : stem + ".iso"
    }

    /// The name the finished ISO takes on the drive: the release's filename,
    /// unwrapped when the release is distributed as an archive.
    public static func placedFileName(for release: Release) -> String? {
        let candidate = release.fileName.isEmpty
            ? release.isoURL?.lastPathComponent
            : release.fileName
        guard let candidate, !candidate.isEmpty else { return nil }
        return isoName(fromArchive: candidate)
    }

    /// PRD F25: copy to a hidden temporary name, rename on completion, so a
    /// failed or interrupted copy never looks like a usable ISO. The dot prefix
    /// also keeps it out of `DriveScan.isoFileNames`.
    public static func partFileName(for finalName: String) -> String {
        ".\(finalName).part"
    }

    /// True for the leftovers of an interrupted copy, cleaned up on the next
    /// connect (DESIGN §6).
    public static func isPartFileName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".part")
    }

    /// The final name a `.part` file was heading for, so cleanup can tell a
    /// stale leftover apart from an unrelated dotfile.
    public static func finalName(ofPartFile name: String) -> String? {
        guard isPartFileName(name), name.count > 6 else { return nil }
        return String(name.dropFirst().dropLast(5))
    }

    // MARK: - Cache keys

    /// Stable, filesystem-safe identity for a cached download. A published
    /// checksum is the natural key (two mirrors of one ISO share a cache entry);
    /// unverified sources fall back to a hash of the URL so the key stays short
    /// and collision-free regardless of how baroque the URL is.
    public static func cacheKey(sha256: String?, sourceURL: URL?, fileName: String) -> String {
        if let sha256, !sha256.isEmpty {
            return "sha256-" + sha256.lowercased()
        }
        let seed = (sourceURL?.absoluteString ?? "") + "|" + fileName
        return "url-" + fnv1aHex(seed)
    }

    /// The cache key of the ISO extracted out of `parentKey`'s archive.
    public static func extractedCacheKey(parentKey: String) -> String {
        parentKey + "-iso"
    }

    /// `<key>-<sanitised name>` — unique via the key, still recognisable to a
    /// human poking around in `~/Library/Caches/Isotope/isos/`.
    public static func cacheFileName(key: String, fileName: String) -> String {
        let safe = sanitize(fileName)
        return safe.isEmpty ? key : "\(key)-\(safe)"
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars.prefix(120))
    }

    /// FNV-1a, 64-bit. Not cryptographic — it only has to be stable across
    /// launches and platforms, which `Hasher` explicitly is not.
    static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
