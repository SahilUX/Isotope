import Foundation

/// Resolves "what is the latest release for this channel" (DESIGN §4.1).
/// Implementations are pure network + parse: no UI, no disk, no globals.
public protocol VersionProvider: Sendable {
    func fetchLatest(config: ProviderConfig) async throws -> Release
}

/// Dispatches a `ProviderConfig` to the implementation for its mechanism.
public struct VersionResolver: VersionProvider {
    public let http: HTTPClient

    /// PRD F50: the client is wrapped so a check that fans out across 100+
    /// channels issues one request per URL, not one per channel. Several
    /// channels legitimately share a URL — an index file, a `SHA256SUMS`, a
    /// release feed — and the duplicate requests are what earn a 429.
    ///
    /// `coalescing: false` hands the client through untouched, which is what
    /// the tests that count requests want.
    public init(http: HTTPClient = URLSessionHTTPClient(), coalescing: Bool = true) {
        self.http = coalescing ? CoalescingHTTPClient(wrapping: http) : http
    }

    public func provider(for config: ProviderConfig) -> VersionProvider {
        switch config.mechanism {
        case .checksumFile: return ChecksumFileProvider(http: http)
        case .gitHubReleases: return GitHubReleasesProvider(http: http)
        case .staticURL: return StaticURLProvider(http: http)
        case .pageScrape: return PageScrapeProvider(http: http)
        case .jsonFeed: return JSONFeedProvider(http: http)
        case .windowsManual: return WindowsInfoProvider(http: http)
        }
    }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        try await provider(for: config).fetchLatest(config: config)
    }
}

// MARK: - Shared behaviour

extension VersionProvider {
    /// Runs an optional `IndexStep` and returns the URL the real request should use.
    func resolveTarget(base: URL, index: IndexStep?, http: HTTPClient) async throws -> URL {
        try await resolveTargets(base: base, index: index, http: http, limit: 1)[0]
    }

    /// The index's versions as target URLs, newest first, at most `limit` of
    /// them. Never empty: no match in the index throws.
    func resolveTargets(base: URL, index: IndexStep?, http: HTTPClient,
                        limit: Int) async throws -> [URL] {
        guard let index else { return [base] }
        let response = try await http.requireData(from: index.url)
        let text = response.text
        let matcher = try PatternMatcher(index.pattern)
        let versions: [VersionToken] = matcher.matches(in: text).compactMap { groups in
            VersionToken.parse(groups.count > 1 ? groups[1] : groups[0])
        }
        guard !versions.isEmpty else {
            throw ProviderError.noMatch(pattern: index.pattern, source: index.url,
                                        snippet: ProviderError.snippet(text))
        }
        var seen = Set<String>()
        let newestFirst = versions.sorted { $1 < $0 }.filter { seen.insert($0.raw).inserted }
        return try newestFirst.prefix(max(1, limit)).map { version in
            let resolved = index.resolvedTarget(version: version.raw)
            guard let url = URL(string: resolved) else { throw ProviderError.unusableURL(resolved) }
            return url
        }
    }

    /// Fetches a `.sha256`-style sidecar; a missing sidecar is not an error
    /// (the release is simply unverified, PRD F21).
    func fetchSidecarChecksum(for url: URL, suffix: String, http: HTTPClient) async -> String? {
        guard let sidecar = URL(string: url.absoluteString + suffix) else { return nil }
        guard let response = try? await http.data(from: sidecar), response.isSuccess else { return nil }
        return ChecksumParsing.singleHash(in: response.text)
    }
}
