import Foundation

/// Resolves "what is the latest release for this channel" (DESIGN §4.1).
/// Implementations are pure network + parse: no UI, no disk, no globals.
public protocol VersionProvider: Sendable {
    func fetchLatest(config: ProviderConfig) async throws -> Release
}

/// Dispatches a `ProviderConfig` to the implementation for its mechanism.
public struct VersionResolver: VersionProvider {
    public let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
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
        guard let index else { return base }
        let response = try await http.requireData(from: index.url)
        let text = response.text
        let matcher = try PatternMatcher(index.pattern)
        let versions: [VersionCandidate] = matcher.matches(in: text).compactMap { groups in
            let raw = groups.count > 1 ? groups[1] : groups[0]
            guard let token = VersionToken.parse(raw) else { return nil }
            return VersionCandidate(version: token, fileName: raw)
        }
        guard let best = versions.highest else {
            throw ProviderError.noMatch(pattern: index.pattern, source: index.url,
                                        snippet: ProviderError.snippet(text))
        }
        let resolved = index.resolvedTarget(version: best.version.raw)
        guard let url = URL(string: resolved) else { throw ProviderError.unusableURL(resolved) }
        return url
    }

    /// Fetches a `.sha256`-style sidecar; a missing sidecar is not an error
    /// (the release is simply unverified, PRD F21).
    func fetchSidecarChecksum(for url: URL, suffix: String, http: HTTPClient) async -> String? {
        guard let sidecar = URL(string: url.absoluteString + suffix) else { return nil }
        guard let response = try? await http.data(from: sidecar), response.isSuccess else { return nil }
        return ChecksumParsing.singleHash(in: response.text)
    }
}
