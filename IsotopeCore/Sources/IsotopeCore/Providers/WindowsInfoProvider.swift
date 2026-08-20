import Foundation

/// PRD §5.4 "Windows caveat". Microsoft's ISO links are session-generated and
/// expire, so this provider deliberately resolves **only** the latest build from
/// the configured info page and returns a `Release` with `isoURL == nil`: there is
/// nothing honest to download from. The UI opens `downloadPage` in the browser
/// instead, and the user's manual download is verified/placed later.
public struct WindowsInfoProvider: VersionProvider {
    /// PRD F43: the tracked identity is the **feature release**, not the build.
    /// Microsoft's own download pages say "Version 25H2" / "Version 22H2", and
    /// that is the token the ISO filenames carry, so it is the only thing an
    /// installed image and a "latest" can honestly be compared on.
    public static let defaultVersionPattern = #"\bVersion (\d{2}H\d)\b"#

    /// The placeholder a `buildPattern` may use for the resolved release token,
    /// so the build belonging to *that* release is the one picked up.
    public static let versionPlaceholder = "{version}"

    /// Microsoft's docs site rejects some non-browser agents outright.
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept": "text/html,application/xhtml+xml"
    ]

    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .windowsManual(let infoURL, _, let versionPattern, _,
                                  let buildInfoURL, let buildPattern) = config else {
            throw ProviderError.unsupportedForMechanism("WindowsInfoProvider was given a \(config.mechanism.rawValue) config.")
        }
        let response = try await http.requireData(from: infoURL, headers: Self.headers)
        let text = response.text
        let pattern = versionPattern ?? Self.defaultVersionPattern
        let matcher = try PatternMatcher(pattern)

        let candidates: [VersionCandidate] = matcher.matches(in: text).compactMap { groups in
            let raw = groups.count > 1 && !groups[1].isEmpty ? groups[1] : groups[0]
            guard let version = VersionToken.parse(raw) else { return nil }
            return VersionCandidate(version: version, fileName: "")
        }
        guard let best = candidates.highest else {
            throw ProviderError.noMatch(pattern: pattern, source: infoURL,
                                        snippet: ProviderError.snippet(text))
        }
        // fileName stays empty and isoURL nil: the download is manual (PRD §5.4).
        return Release(version: best.version, isoURL: nil, fileName: "", sha256: nil, sizeBytes: nil,
                       build: await build(url: buildInfoURL, pattern: buildPattern,
                                          version: best.version.raw))
    }

    /// PRD F43: the OS build number for the resolved feature release — shown
    /// next to it, and compared against the build read out of the image on the
    /// drive. A second, optional, entirely best-effort request: every failure
    /// path returns nil, because a missing detail must never fail a check.
    private func build(url: URL?, pattern: String?, version: String) async -> String? {
        guard let url, let pattern, !pattern.isEmpty else { return nil }
        let resolved = pattern.replacingOccurrences(of: Self.versionPlaceholder, with: version)
        guard let matcher = try? PatternMatcher(resolved),
              let response = try? await http.requireData(from: url, headers: Self.headers),
              let build = matcher.capturedVersion(in: response.text), !build.isEmpty
        else { return nil }
        return build
    }
}
