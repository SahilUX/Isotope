import Foundation

/// An optional first request that resolves a moving path segment (a release
/// series, a version directory) before the real request is made.
///
/// Ubuntu, Linux Mint and openSUSE all publish their checksum/listing files
/// under a per-version path, so a single constant URL cannot describe them.
/// `url` is fetched, `pattern` is matched everywhere in the body, capture group
/// 1 of every match is parsed as a `VersionToken`, the highest wins, and its raw
/// text is substituted for `{version}` in `target` to produce the real request
/// URL. When an index step is present the enclosing case's own `url` is unused
/// (it is kept in the JSON as a human-readable example of what gets fetched).
public struct IndexStep: Codable, Hashable, Sendable {
    public var url: URL
    /// Regex with one capture group holding the version/series text.
    public var pattern: String
    /// URL template containing `{version}`.
    public var target: String

    public init(url: URL, pattern: String, target: String) {
        self.url = url
        self.pattern = pattern
        self.target = target
    }

    public func resolvedTarget(version: String) -> String {
        target.replacingOccurrences(of: "{version}", with: version)
    }
}

/// How a channel resolves its latest `Release` (PRD §5).
/// Encoded as a discriminated union: `{"mechanism": "...", ...fields}` so that
/// `catalog.json` and `custom-sources.json` stay hand-editable.
public enum ProviderConfig: Codable, Hashable, Sendable {
    /// Fetch a SHA256SUMS-style file; `filePattern` is a regex over filenames with a version capture group.
    /// `downloadBase` overrides where the ISO lives when it is not a sibling of the checksum file.
    case checksumFile(url: URL, filePattern: String, index: IndexStep? = nil, downloadBase: URL? = nil)
    /// GitHub Releases API; `repo` is "owner/name", `assetPattern` a regex over asset names.
    case gitHubReleases(repo: String, assetPattern: String)
    /// Constant URL whose content changes; version is the ETag/Last-Modified change date.
    /// `fileNamePattern` is recognition-only (PRD F41): the filename holds no
    /// change date, so it carries no version capture group.
    case staticURL(url: URL, checksumURL: URL?, fileNamePattern: String? = nil)
    /// Scrape anchors from a listing page; `linkPattern` is a regex with a version capture group.
    /// `checksumSuffix` (e.g. ".sha256") is appended to the winning ISO URL to recover a checksum.
    case pageScrape(url: URL, linkPattern: String, index: IndexStep? = nil, checksumSuffix: String? = nil)
    /// A JSON endpoint listing releases (Fedora, Pop!_OS, Tails). Field lookups use
    /// `JSONPath`'s mini-language so format drift is fixed by editing JSON, not code.
    /// `fileNamePattern` lets drive scans recognise the feed's ISOs (PRD F41); it
    /// captures a version only where the filename really holds the feed's own
    /// version (Fedora, Tails) — Pop!_OS splits release and build across two
    /// segments a single group cannot rejoin, so its pattern captures nothing.
    case jsonFeed(url: URL, spec: JSONFeedSpec, fileNamePattern: String? = nil)
    /// Windows: track the **feature release**, hand the download off to the
    /// browser (PRD §5.4, F43).
    ///
    /// `infoURL` is fetched and `versionPattern`'s capture group 1 is parsed as a
    /// `VersionToken`; for Windows that is now the `NNHN` release token ("25H2"),
    /// because that is the identity the downloadable install media actually
    /// carries and the identity Microsoft's own filenames encode.
    /// `fileNamePattern` recognises Microsoft's official media names on a drive
    /// (PRD F41) and now captures that same release token, so an adopted
    /// `Win11_25H2_English_x64_v2.iso` compares against the resolved release
    /// instead of reporting "Unknown".
    ///
    /// `buildInfoURL` + `buildPattern` are optional and purely cosmetic (F43:
    /// "the build number stays as display detail only"). When both are present
    /// the page is fetched as a second, best-effort request; `{version}` in the
    /// pattern is replaced by the resolved release token so the build belonging
    /// to *that* release is the one picked up. Any failure — network, no match,
    /// pattern drift — is swallowed and simply leaves the detail off.
    ///
    /// `mediaCatalog` (PRD F48) is the one Microsoft endpoint that answers
    /// without a browser: it names the release *and the media revision* being
    /// served right now ("Windows 11 25H2__V2"). When present it supersedes the
    /// page scrape for the release token and adds the revision, which is the
    /// only Windows difference the user can actually act on.
    case windowsManual(infoURL: URL, downloadPage: URL, versionPattern: String? = nil,
                       fileNamePattern: String? = nil,
                       buildInfoURL: URL? = nil, buildPattern: String? = nil,
                       mediaCatalog: WindowsMediaCatalog? = nil)

    public enum Mechanism: String, Codable, CaseIterable, Sendable {
        case checksumFile, gitHubReleases, staticURL, pageScrape, jsonFeed, windowsManual
    }

    public var mechanism: Mechanism {
        switch self {
        case .checksumFile: return .checksumFile
        case .gitHubReleases: return .gitHubReleases
        case .staticURL: return .staticURL
        case .pageScrape: return .pageScrape
        case .jsonFeed: return .jsonFeed
        case .windowsManual: return .windowsManual
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mechanism, url, filePattern, index, downloadBase, repo, assetPattern, checksumURL
        case linkPattern, checksumSuffix, infoURL, downloadPage, versionPattern, fileNamePattern
        case buildInfoURL, buildPattern
        case itemsPath, filter, versionKeys, isoURLKey, sha256Key, sizeKey, fileNameKey
        case mediaCatalog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Mechanism.self, forKey: .mechanism) {
        case .checksumFile:
            self = .checksumFile(url: try c.decode(URL.self, forKey: .url),
                                 filePattern: try c.decode(String.self, forKey: .filePattern),
                                 index: try c.decodeIfPresent(IndexStep.self, forKey: .index),
                                 downloadBase: try c.decodeIfPresent(URL.self, forKey: .downloadBase))
        case .gitHubReleases:
            self = .gitHubReleases(repo: try c.decode(String.self, forKey: .repo),
                                   assetPattern: try c.decode(String.self, forKey: .assetPattern))
        case .staticURL:
            self = .staticURL(url: try c.decode(URL.self, forKey: .url),
                              checksumURL: try c.decodeIfPresent(URL.self, forKey: .checksumURL),
                              fileNamePattern: try c.decodeIfPresent(String.self, forKey: .fileNamePattern))
        case .pageScrape:
            self = .pageScrape(url: try c.decode(URL.self, forKey: .url),
                               linkPattern: try c.decode(String.self, forKey: .linkPattern),
                               index: try c.decodeIfPresent(IndexStep.self, forKey: .index),
                               checksumSuffix: try c.decodeIfPresent(String.self, forKey: .checksumSuffix))
        case .jsonFeed:
            self = .jsonFeed(url: try c.decode(URL.self, forKey: .url),
                             spec: try JSONFeedSpec(from: decoder),
                             fileNamePattern: try c.decodeIfPresent(String.self, forKey: .fileNamePattern))
        case .windowsManual:
            self = .windowsManual(infoURL: try c.decode(URL.self, forKey: .infoURL),
                                  downloadPage: try c.decode(URL.self, forKey: .downloadPage),
                                  versionPattern: try c.decodeIfPresent(String.self, forKey: .versionPattern),
                                  fileNamePattern: try c.decodeIfPresent(String.self, forKey: .fileNamePattern),
                                  buildInfoURL: try c.decodeIfPresent(URL.self, forKey: .buildInfoURL),
                                  buildPattern: try c.decodeIfPresent(String.self, forKey: .buildPattern),
                                  mediaCatalog: try c.decodeIfPresent(WindowsMediaCatalog.self, forKey: .mediaCatalog))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mechanism, forKey: .mechanism)
        switch self {
        case .checksumFile(let url, let filePattern, let index, let downloadBase):
            try c.encode(url, forKey: .url)
            try c.encode(filePattern, forKey: .filePattern)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encodeIfPresent(downloadBase, forKey: .downloadBase)
        case .gitHubReleases(let repo, let assetPattern):
            try c.encode(repo, forKey: .repo)
            try c.encode(assetPattern, forKey: .assetPattern)
        case .staticURL(let url, let checksumURL, let fileNamePattern):
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(checksumURL, forKey: .checksumURL)
            try c.encodeIfPresent(fileNamePattern, forKey: .fileNamePattern)
        case .pageScrape(let url, let linkPattern, let index, let checksumSuffix):
            try c.encode(url, forKey: .url)
            try c.encode(linkPattern, forKey: .linkPattern)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encodeIfPresent(checksumSuffix, forKey: .checksumSuffix)
        case .jsonFeed(let url, let spec, let fileNamePattern):
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(fileNamePattern, forKey: .fileNamePattern)
            try spec.encode(to: encoder)
        case .windowsManual(let infoURL, let downloadPage, let versionPattern, let fileNamePattern,
                            let buildInfoURL, let buildPattern, let mediaCatalog):
            try c.encode(infoURL, forKey: .infoURL)
            try c.encode(downloadPage, forKey: .downloadPage)
            try c.encodeIfPresent(versionPattern, forKey: .versionPattern)
            try c.encodeIfPresent(fileNamePattern, forKey: .fileNamePattern)
            try c.encodeIfPresent(buildInfoURL, forKey: .buildInfoURL)
            try c.encodeIfPresent(buildPattern, forKey: .buildPattern)
            try c.encodeIfPresent(mediaCatalog, forKey: .mediaCatalog)
        }
    }
}

/// Field mapping for `.jsonFeed`. Every key is a `JSONPath` expression evaluated
/// against one item of the feed.
public struct JSONFeedSpec: Codable, Hashable, Sendable {
    /// Path to the array of release objects; nil/empty means the document root
    /// (an object root is treated as a single-item list, e.g. Pop!_OS).
    public var itemsPath: String?
    /// All pairs must match (string comparison) for an item to be considered.
    public var filter: [String: String]?
    /// Paths whose values are joined with "." to form the version string;
    /// several keys let a build number extend a stable release number.
    public var versionKeys: [String]
    public var isoURLKey: String?
    public var sha256Key: String?
    public var sizeKey: String?
    /// Optional; by default the filename is the last path component of the ISO URL.
    public var fileNameKey: String?

    public init(itemsPath: String? = nil, filter: [String: String]? = nil, versionKeys: [String],
                isoURLKey: String? = nil, sha256Key: String? = nil, sizeKey: String? = nil,
                fileNameKey: String? = nil) {
        self.itemsPath = itemsPath
        self.filter = filter
        self.versionKeys = versionKeys
        self.isoURLKey = isoURLKey
        self.sha256Key = sha256Key
        self.sizeKey = sizeKey
        self.fileNameKey = fileNameKey
    }
}
