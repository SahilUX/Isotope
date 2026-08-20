import Foundation

/// What a Windows install image says about itself (PRD F43 addendum).
///
/// Microsoft's ISO filenames carry the feature release and nothing else:
/// `Win11_25H2_English_x64.iso` is the same name whether the media is build
/// 26200.6584 or 26200.9168, and Microsoft refreshes the media without
/// renaming it. The build is written *inside* the image — in the XML resource
/// of `sources/install.wim` — so that is where it has to be read from.
public struct WindowsImageIdentity: Codable, Hashable, Sendable {
    /// `<BUILD>.<SPBUILD>`, e.g. "26200.9168". The same shape Microsoft's
    /// release-health pages print, so the two sides are comparable.
    public var build: String
    /// The editions the image contains ("Professional", "Home"), in image
    /// order. Display only; an ISO is not identified by its edition list.
    public var editions: [String]

    public init(build: String, editions: [String] = []) {
        self.build = build
        self.editions = editions
    }

    /// The build as a comparable token. `.semantic([26200, 9168])`, so
    /// 26200.9168 > 26200.6584 falls out of the ordinary version comparison.
    public var buildToken: VersionToken? { VersionToken.parse(build) }
}

/// Reads the metadata block of a WIM/ESD container (`sources/install.wim`,
/// `install.esd`, `install.swm`).
///
/// Foundation only and I/O-free: the caller reads the byte ranges — from a
/// mounted ISO on macOS, from a loop mount on Linux later — and hands them in.
/// That keeps the format knowledge portable and, more usefully, testable
/// without a 6 GB ISO.
///
/// Layout (`WIMHEADER_V1_PACKED`, 208 bytes, all little-endian):
///
/// ```
/// 0x00  CHAR      ImageTag[8]        "MSWIM\0\0\0"
/// 0x08  DWORD     cbSize
/// 0x0C  DWORD     dwVersion
/// 0x10  DWORD     dwFlags
/// 0x14  DWORD     dwCompressionSize
/// 0x18  GUID      gWIMGuid
/// 0x28  USHORT    usPartNumber
/// 0x2A  USHORT    usTotalParts
/// 0x2C  DWORD     dwImageCount
/// 0x30  RESHDR    rhOffsetTable
/// 0x48  RESHDR    rhXmlData          ← the XML this reads
/// ...
/// ```
///
/// A `RESHDR_DISK_SHORT` is 24 bytes: a packed size/flags word (56-bit size,
/// top byte flags), an 8-byte offset, and an 8-byte original size.
public enum WindowsImageReader {
    public static let headerLength = 208
    /// `RESHDR_FLAG_COMPRESSED`. The XML resource is stored uncompressed in
    /// every image Microsoft ships; if one ever is not, this reader reports
    /// nothing rather than decoding a compression format it does not implement.
    private static let compressedFlag: UInt8 = 0x04
    private static let magic = Array("MSWIM\0\0\0".utf8)
    /// A WIM's XML block is tens of kilobytes. The cap bounds what a corrupt or
    /// hostile header can make the caller read.
    public static let maxXMLBytes: UInt64 = 16 * 1024 * 1024

    /// Where the XML resource lives, from the 208-byte header.
    ///
    /// Nil when the file is not a WIM, when the header is short, when the
    /// resource is compressed or empty, or when offset/size are implausible —
    /// every one of which means "this image will not tell us its build", which
    /// the caller reports as unknown.
    public static func xmlResource(header: Data) -> (offset: UInt64, size: UInt64)? {
        let bytes = [UInt8](header)
        guard bytes.count >= headerLength, Array(bytes[0..<8]) == magic else { return nil }

        let packed = readUInt64(bytes, at: 0x48)
        let size = packed & 0x00FF_FFFF_FFFF_FFFF
        let flags = UInt8(truncatingIfNeeded: packed >> 56)
        let offset = readUInt64(bytes, at: 0x50)

        guard flags & compressedFlag == 0, size > 0, size <= maxXMLBytes, offset >= UInt64(headerLength)
        else { return nil }
        return (offset, size)
    }

    /// The XML resource is UTF-16LE with a byte-order mark.
    public static func decodeXML(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let text = String(data: data, encoding: .utf16LittleEndian)
        guard let text, !text.isEmpty else { return nil }
        // Strip the BOM, which survives the decode as U+FEFF.
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// The identity in a decoded XML block.
    ///
    /// A multi-edition ISO carries one `<IMAGE>` per edition, all built at the
    /// same time; the highest build wins so a mixed image cannot be reported as
    /// older than it is. Nil when no `<VERSION>` block parses — an image that
    /// does not say is left saying nothing.
    public static func identity(xml: String) -> WindowsImageIdentity? {
        guard let versions = try? PatternMatcher(
            #"<BUILD>(\d+)</BUILD>\s*<SPBUILD>(\d+)</SPBUILD>"#, caseInsensitive: true)
        else { return nil }

        var best: (build: Int, spBuild: Int)?
        for groups in versions.matches(in: xml) where groups.count > 2 {
            guard let build = Int(groups[1]), let spBuild = Int(groups[2]) else { continue }
            if let current = best, (build, spBuild) <= (current.build, current.spBuild) { continue }
            best = (build, spBuild)
        }
        guard let best else { return nil }

        var editions: [String] = []
        if let matcher = try? PatternMatcher(#"<EDITIONID>([^<]+)</EDITIONID>"#, caseInsensitive: true) {
            for groups in matcher.matches(in: xml) where groups.count > 1 {
                let edition = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !edition.isEmpty, !editions.contains(edition) { editions.append(edition) }
            }
        }
        return WindowsImageIdentity(build: "\(best.build).\(best.spBuild)", editions: editions)
    }

    /// The file names, in preference order, that hold the metadata inside a
    /// mounted Windows ISO. `install.esd` is a solid-compressed WIM and carries
    /// the same header; `install.swm` is the first part of a split WIM, which
    /// carries the XML like any other part 1.
    public static let installImageNames = ["install.wim", "install.esd", "install.swm"]

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}
