import Foundation

/// PRD §5.4 — page/directory scrape. Anchors are extracted with a regex (no HTML
/// parser dependency), matched against `linkPattern`, and the highest captured
/// version wins. The most fragile mechanism; the Test button (F10) is what makes
/// the regex debuggable at creation time.
public struct PageScrapeProvider: VersionProvider {
    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .pageScrape(let url, let linkPattern, let index, let checksumSuffix) = config else {
            throw ProviderError.unsupportedForMechanism("PageScrapeProvider was given a \(config.mechanism.rawValue) config.")
        }
        let target = try await resolveTarget(base: url, index: index, http: http)
        let response = try await http.requireData(from: target)
        let html = response.text
        let matcher = try PatternMatcher(linkPattern)
        // The page's own URL after redirects is the correct base for relative hrefs.
        let base = response.url

        var candidates: [VersionCandidate] = []
        var seen = Set<String>()
        for href in HTMLParsing.hrefs(in: html) {
            guard let groups = matcher.firstMatch(in: href) else { continue }
            let raw = groups.count > 1 && !groups[1].isEmpty ? groups[1] : groups[0]
            guard let version = VersionToken.parse(raw) else { continue }
            guard let absolute = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            guard seen.insert(absolute.absoluteString).inserted else { continue }
            candidates.append(VersionCandidate(version: version,
                                               fileName: absolute.lastPathComponent,
                                               url: absolute))
        }
        guard let best = candidates.highest, let isoURL = best.url else {
            throw ProviderError.noMatch(pattern: linkPattern, source: target,
                                        snippet: ProviderError.snippet(html))
        }

        var sha: String?
        if let checksumSuffix, !checksumSuffix.isEmpty {
            sha = await fetchSidecarChecksum(for: isoURL, suffix: checksumSuffix, http: http)
        }
        return Release(version: best.version, isoURL: isoURL, fileName: best.fileName, sha256: sha)
    }
}
