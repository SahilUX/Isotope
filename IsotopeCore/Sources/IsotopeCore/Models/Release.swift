import Foundation

/// The resolved "latest" for a channel at `checkedAt`.
public struct Release: Codable, Hashable, Sendable {
    public var version: VersionToken
    public var isoURL: URL?
    public var fileName: String
    public var sha256: String?
    public var sizeBytes: Int64?
    public var checkedAt: Date
    /// PRD F43: the OS build that belongs to this release, where the source
    /// publishes one — Windows' "26200.9168" next to the feature release
    /// "25H2". Nil for every source that has nothing to add.
    ///
    /// It is *not* part of `version`, and the two are never mixed: a feature
    /// release and a build number are different namespaces (see `VersionToken`).
    /// What it is compared against is the build read out of the installed image
    /// itself (`InstalledISO.build`), which is the only like-for-like there is.
    public var build: String?

    /// PRD F21: no published checksum → the UI must label the download unverified.
    public var isVerifiable: Bool { sha256?.isEmpty == false }

    /// "build 26200.9168" — the build as it is shown beside the version.
    public var displayDetail: String? {
        guard let build, !build.isEmpty else { return nil }
        return "build \(build)"
    }

    /// "25H2 (build 26200.9168)", or just "24.04.4" when there is no detail.
    public var displayVersion: String {
        guard let displayDetail else { return version.raw }
        return "\(version.raw) (\(displayDetail))"
    }

    public init(version: VersionToken, isoURL: URL? = nil, fileName: String,
                sha256: String? = nil, sizeBytes: Int64? = nil, checkedAt: Date = Date(),
                build: String? = nil) {
        self.version = version
        self.isoURL = isoURL
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.checkedAt = checkedAt
        self.build = build
    }
}

/// Key used to cache resolved releases per (entry, channel).
public struct ReleaseKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public var entryID: String
    public var channelID: String

    public init(entryID: String, channelID: String) {
        self.entryID = entryID
        self.channelID = channelID
    }

    public var description: String { "\(entryID)#\(channelID)" }
}
