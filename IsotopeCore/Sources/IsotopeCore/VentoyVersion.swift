import Foundation

/// The Ventoy release installed on a Ventoy drive (PRD F74), as read from the
/// drive's small VTOYEFI partition.
///
/// Ventoy writes its version into `/grub/grub.cfg` on partition 2 as
/// `set VENTOY_VERSION="1.1.18"`, and Ventoy2Disk itself reads it back the same
/// way: the quoted value after `VENTOY_VERSION=`. This type owns that format
/// knowledge and the comparison; mounting the partition is the app's job.
public struct VentoyVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Numeric components, most significant first: 1.1.14 → [1, 1, 14].
    public let components: [Int]

    /// Parses "1.1.14". Anything that is not dot-separated decimal numbers
    /// (an empty string, "1.1.x", "v1.1") is refused rather than guessed at.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 6 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Numeric, component by component, with missing trailing components read
    /// as zero: 1.1.9 < 1.1.14 < 1.1.18, and 1.1 == 1.1.0.
    public static func < (lhs: VentoyVersion, rhs: VentoyVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: VentoyVersion, rhs: VentoyVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    // MARK: - grub.cfg

    /// The version recorded in a Ventoy `grub.cfg`, or nil when the text has
    /// no parsable `VENTOY_VERSION="…"` line.
    ///
    /// Tolerates a leading `set`, surrounding whitespace and tabs, and CRLF
    /// line endings. Commented lines are skipped. The first valid assignment
    /// wins, which matches the order GRUB itself evaluates them in.
    public static func parse(grubConfig text: String) -> VentoyVersion? {
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = Substring(rawLine).drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("set") {
                let rest = line.dropFirst(3)
                guard let first = rest.first, first == " " || first == "\t" else { continue }
                line = rest.drop { $0 == " " || $0 == "\t" }
            }
            let key = "VENTOY_VERSION"
            guard line.hasPrefix(key) else { continue }
            var rest = line.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else { continue }
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard rest.first == "\"" else { continue }
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { continue }
            if let version = VentoyVersion(String(rest[..<close])) { return version }
        }
        return nil
    }

    // MARK: - Secure Boot policy

    /// Ventoy 1.1.14 moved to the Secure Boot shim signed under Microsoft's
    /// 2023 UEFI CA. Anything older relies on the 2011 CA, which PCs that have
    /// applied the revocation no longer trust.
    public static let newSecureBootCA = VentoyVersion("1.1.14")!

    /// Whether this release predates the new Secure Boot CA.
    public var needsSecureBootCANotice: Bool { self < Self.newSecureBootCA }
}

/// What the app knows about a connected Ventoy drive's Ventoy install.
public enum VentoyVersionReading: Equatable, Sendable {
    case known(VentoyVersion)
    /// Not read, or the read failed; the reason is for logs and tooltips.
    case unknown(String)

    public var version: VentoyVersion? {
        if case .known(let version) = self { return version }
        return nil
    }

    /// True only for a known version older than 1.1.14. An unknown version
    /// gets no warning: Isotope does not claim what it could not read.
    public var needsSecureBootCANotice: Bool { version?.needsSecureBootCANotice ?? false }
}

// MARK: - Which partition may be read

/// What the app found as partition 2 of a Ventoy drive's whole disk, before
/// deciding whether to mount it (PRD F74). Filled from DiskArbitration by the
/// app; plain data here so the rule is testable without hardware.
public struct VentoyEFIPartitionCandidate: Equatable, Sendable {
    /// The whole disk the drive's mounted data volume lives on ("disk4").
    public var dataWholeDisk: String
    /// The partition being considered ("disk4s2").
    public var partitionBSDName: String
    /// The whole disk DiskArbitration says that partition belongs to.
    public var partitionWholeDisk: String
    public var sizeBytes: Int64
    /// `DAMediaContent`: "0xEF" on an MBR disk, the EFI System GUID on GPT.
    public var content: String?
    /// The whole disk, as the registration gates see it.
    public var disk: FlashDeviceDescription

    public init(dataWholeDisk: String, partitionBSDName: String, partitionWholeDisk: String,
                sizeBytes: Int64, content: String?, disk: FlashDeviceDescription) {
        self.dataWholeDisk = dataWholeDisk
        self.partitionBSDName = partitionBSDName
        self.partitionWholeDisk = partitionWholeDisk
        self.sizeBytes = sizeBytes
        self.content = content
        self.disk = disk
    }
}

public enum VentoyEFIPartitionRule {
    /// Ventoy's VTOYEFI partition is 32 MB. A window around it, not an exact
    /// match, so a future Ventoy that resizes it a little still reads.
    public static let minimumBytes: Int64 = 16 * 1024 * 1024
    public static let maximumBytes: Int64 = 64 * 1024 * 1024

    static let gptEFISystemGUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    /// Partition types that may hold VTOYEFI: MBR type 0xEF (Ventoy's
    /// default) or the GPT EFI System partition (Ventoy's GPT option).
    public static func isEFIType(_ content: String?) -> Bool {
        guard let content = content?.trimmingCharacters(in: .whitespaces) else { return false }
        return content.caseInsensitiveCompare("0xEF") == .orderedSame
            || content.caseInsensitiveCompare(gptEFISystemGUID) == .orderedSame
            || content.caseInsensitiveCompare("EFI") == .orderedSame
    }

    /// Why this partition must not be mounted, or nil when it may be. The
    /// whole disk must pass the same gate as registration (external,
    /// removable, USB, whole, not the boot disk).
    public static func refusal(for candidate: VentoyEFIPartitionCandidate) -> String? {
        guard candidate.partitionWholeDisk == candidate.dataWholeDisk,
              candidate.disk.bsdName == candidate.dataWholeDisk,
              candidate.partitionBSDName == "\(candidate.dataWholeDisk)s2"
        else { return "partition 2 is not on the drive's own disk" }
        guard (minimumBytes...maximumBytes).contains(candidate.sizeBytes) else {
            return "partition 2 is not the size of a Ventoy EFI partition"
        }
        guard isEFIType(candidate.content) else { return "partition 2 is not an EFI partition" }
        guard FlashSafetyGate.isEligibleForRegistration(candidate.disk) else {
            return "the drive is not an external USB disk"
        }
        return nil
    }
}
