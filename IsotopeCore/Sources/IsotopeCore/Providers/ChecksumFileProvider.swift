import Foundation

/// PRD §5.1 — checksum-file watch. One small GET yields filename, version and
/// SHA-256 together, so verification comes free. The cheapest, most reliable
/// mechanism and the default for built-in entries.
public struct ChecksumFileProvider: VersionProvider {
    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .checksumFile(let url, let filePattern, let index, let downloadBase) = config else {
            throw ProviderError.unsupportedForMechanism("ChecksumFileProvider was given a \(config.mechanism.rawValue) config.")
        }
        let target = try await resolveTarget(base: url, index: index, http: http)
        let response = try await http.requireData(from: target)
        let text = response.text
        let matcher = try PatternMatcher(filePattern)

        let candidates: [VersionCandidate] = ChecksumParsing.lines(in: text).compactMap { line in
            guard let raw = matcher.capturedVersion(in: line.fileName),
                  let version = VersionToken.parse(raw) else { return nil }
            return VersionCandidate(version: version, fileName: line.fileName, sha256: line.hash)
        }
        guard let best = candidates.highest else {
            throw ProviderError.noMatch(pattern: filePattern, source: target,
                                        snippet: ProviderError.snippet(text))
        }

        // The ISO normally sits next to its checksum file; `downloadBase` covers
        // the projects that publish sums on their own site and binaries on a CDN.
        let base = downloadBase ?? target.deletingLastPathComponent()
        let isoURL = URL(string: best.fileName, relativeTo: base)?.absoluteURL

        return Release(version: best.version, isoURL: isoURL, fileName: best.fileName,
                       sha256: best.sha256)
    }
}
