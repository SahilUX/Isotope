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
        // The newest indexed version can lack a usable SHA-256: Ubuntu MATE
        // skipped 26.04, and Parrot 7.4 shipped with MD5s only. Fall back to the
        // newest version that has one rather than offer nothing, or something
        // unverified. The first failure is what gets reported if none do.
        let targets = try await resolveTargets(base: url, index: index, http: http,
                                               limit: Self.indexFallbackDepth)
        let matcher = try PatternMatcher(filePattern)
        var firstFailure: Error?
        for target in targets {
            do {
                return try await release(from: target, matcher: matcher,
                                         filePattern: filePattern, downloadBase: downloadBase)
            } catch let error as ProviderError where error.allowsIndexFallback {
                firstFailure = firstFailure ?? error
            }
        }
        throw firstFailure!
    }

    /// How many indexed versions to try, newest first.
    static let indexFallbackDepth = 3

    private func release(from target: URL, matcher: PatternMatcher, filePattern: String,
                         downloadBase: URL?) async throws -> Release {
        let response = try await http.requireData(from: target)
        let text = response.text

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

private extension ProviderError {
    /// A version directory that is missing, or has no SHA-256 for the file.
    /// Anything else (a timeout, a 5xx) is not a reason to go back a version.
    var allowsIndexFallback: Bool {
        switch self {
        case .noMatch: return true
        case .httpStatus(let code, _): return code == 404
        default: return false
        }
    }
}
