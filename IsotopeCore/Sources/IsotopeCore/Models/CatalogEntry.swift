import Foundation

/// A trackable ISO source: built-in (bundled `catalog.json`) or user-created.
public struct CatalogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case linux, tool, windows, custom
    }

    public var id: String              // "ubuntu-desktop", "custom-<uuid>"
    public var name: String
    public var kind: Kind
    /// PRD F38: the family the Catalog view groups this entry under ("Ubuntu",
    /// "Microsoft", "Tools & rescue"). Flavours share their parent's family, so
    /// Kubuntu sits under "Ubuntu" rather than in a section of its own.
    public var organization: String
    public var homepage: URL?
    public var channels: [Channel]     // ≥1; a single "default" channel when the entry has no variants
    public var isBuiltIn: Bool
    /// PRD F40: regex over a USB volume label, with an *optional* version in
    /// capture group 1. A dd-flashed stick keeps the ISO's own volume label, so
    /// matching it identifies what a stick appears to contain without reading a
    /// single raw byte. Nil when the label carries nothing distinctive enough to
    /// match on (guessing wrong is worse than not guessing).
    ///
    /// Entry level is the default because most labels name the distribution and
    /// not the variant; a `Channel` may override it when the channels really do
    /// differ (Debian's netinst/DVD labels, NixOS's minimal/graphical images).
    public var volumeLabelPattern: String?
    /// PRD F44: ordered marker files to read from a flashed drive's mounted
    /// volume when the label alone cannot say which version is on it. Empty for
    /// every entry whose image carries no readable marker — inventing a path is
    /// how a probe starts reporting the wrong version.
    ///
    /// Entry level, like `volumeLabelPattern`, because the marker file is a
    /// property of the image family rather than of the variant; a `Channel` may
    /// override it where the channels genuinely differ.
    public var contentProbes: [ContentProbe]

    public init(id: String, name: String, kind: Kind, organization: String? = nil,
                homepage: URL? = nil, channels: [Channel], isBuiltIn: Bool,
                volumeLabelPattern: String? = nil, contentProbes: [ContentProbe] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.organization = organization ?? Self.defaultOrganization(kind: kind, name: name)
        self.homepage = homepage
        self.channels = channels
        self.isBuiltIn = isBuiltIn
        self.volumeLabelPattern = volumeLabelPattern
        self.contentProbes = contentProbes
    }

    /// Hand-written for the same reason `ManagedDrive`'s is: a synthesised
    /// decoder does not fall back to a property's default value, so every
    /// `custom-sources.json` written before v1.3 — none of which has an
    /// `organization` — would fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        homepage = try c.decodeIfPresent(URL.self, forKey: .homepage)
        channels = try c.decode([Channel].self, forKey: .channels)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        volumeLabelPattern = try c.decodeIfPresent(String.self, forKey: .volumeLabelPattern)
        contentProbes = try c.decodeIfPresent([ContentProbe].self, forKey: .contentProbes) ?? []
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
            ?? Self.defaultOrganization(kind: kind, name: name)
    }

    /// What an entry without an explicit organization is filed under. User
    /// sources land in one "Custom" section; a built-in that forgot the field
    /// gets its own name, which is visible enough to be noticed and fixed.
    public static func defaultOrganization(kind: Kind, name: String) -> String {
        kind == .custom ? "Custom" : name
    }

    public func channel(id channelID: String) -> Channel? {
        channels.first { $0.id == channelID }
    }

    /// The label pattern that applies to `channelID`, falling back to the
    /// entry's own.
    public func volumeLabelPattern(forChannel channelID: String?) -> String? {
        guard let channelID, let channel = channel(id: channelID) else { return volumeLabelPattern }
        return channel.volumeLabelPattern ?? volumeLabelPattern
    }

    /// PRD F44: the probes that apply to `channelID`. A channel's own list
    /// *replaces* the entry's rather than extending it — a channel that declares
    /// probes is saying "these, in this order", and silently appending the
    /// entry's would defeat the ordering the list exists to express.
    public func contentProbes(forChannel channelID: String?) -> [ContentProbe] {
        guard let channelID, let channel = channel(id: channelID),
              let overrides = channel.contentProbes, !overrides.isEmpty
        else { return contentProbes }
        return overrides
    }
}

/// A variant within an entry (Ubuntu LTS vs Latest, Debian netinst vs DVD).
public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var id: String              // "lts", "latest", "netinst", "default"
    public var name: String
    public var provider: ProviderConfig
    /// PRD F40, optional override of `CatalogEntry.volumeLabelPattern` for the
    /// channels whose images carry distinguishable labels.
    public var volumeLabelPattern: String?
    /// PRD F44, optional override of `CatalogEntry.contentProbes`. Nil (the
    /// common case) means "use the entry's".
    public var contentProbes: [ContentProbe]?

    public init(id: String, name: String, provider: ProviderConfig,
                volumeLabelPattern: String? = nil, contentProbes: [ContentProbe]? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.volumeLabelPattern = volumeLabelPattern
        self.contentProbes = contentProbes
    }
}

// MARK: - Grouping (PRD F38)

public extension Array where Element == CatalogEntry {
    /// Entries grouped by organization, preserving catalog order both for the
    /// sections and within them — the order in `catalog.json` is the author's
    /// choice, so grouping must not silently re-sort it.
    func groupedByOrganization() -> [(organization: String, entries: [CatalogEntry])] {
        var order: [String] = []
        var buckets: [String: [CatalogEntry]] = [:]
        for entry in self {
            if buckets[entry.organization] == nil { order.append(entry.organization) }
            buckets[entry.organization, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
