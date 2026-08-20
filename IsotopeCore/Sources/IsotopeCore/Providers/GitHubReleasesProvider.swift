import Foundation

/// PRD §5.2 — GitHub Releases. Version comes from the release tag, the ISO from
/// the first asset matching `assetPattern`, and the checksum from a sibling
/// `.sha256`/`SHA256SUMS` asset when the project publishes one.
public struct GitHubReleasesProvider: VersionProvider {
    /// Unauthenticated GitHub API requests are rejected without a User-Agent.
    public static let apiHeaders = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": URLSessionHTTPClient.userAgent
    ]

    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .gitHubReleases(let repo, let assetPattern) = config else {
            throw ProviderError.unsupportedForMechanism("GitHubReleasesProvider was given a \(config.mechanism.rawValue) config.")
        }
        let path = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let listURL = URL(string: "https://api.github.com/repos/\(path)/releases?per_page=20") else {
            throw ProviderError.unusableURL(repo)
        }
        let response = try await http.requireData(from: listURL, headers: Self.apiHeaders)
        guard let releases = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            throw ProviderError.invalidResponse(listURL)
        }
        let matcher = try PatternMatcher(assetPattern)

        for release in releases {
            if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { continue }
            guard let tag = release["tag_name"] as? String,
                  let version = VersionToken.parse(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) else { continue }
            let assets = (release["assets"] as? [[String: Any]]) ?? []
            guard let asset = assets.first(where: { asset in
                (asset["name"] as? String).map(matcher.matchesAnywhere) == true
            }), let name = asset["name"] as? String,
               let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }

            let size = (asset["size"] as? NSNumber)?.int64Value
            let sha = await checksum(forAssetNamed: name, in: assets)
            return Release(version: version, isoURL: download, fileName: name,
                           sha256: sha, sizeBytes: size)
        }
        throw ProviderError.noMatch(pattern: assetPattern, source: listURL,
                                    snippet: ProviderError.snippet(response.text))
    }

    /// Looks for `<asset>.sha256` / `<asset>.sha256sum`, then for a repo-wide
    /// sums asset that mentions the ISO by name.
    private func checksum(forAssetNamed name: String, in assets: [[String: Any]]) async -> String? {
        func url(named candidate: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased() == candidate.lowercased() }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }

        for suffix in [".sha256", ".sha256sum", ".SHA256"] {
            guard let sidecar = url(named: name + suffix),
                  let response = try? await http.data(from: sidecar, headers: Self.apiHeaders),
                  response.isSuccess else { continue }
            if let hash = ChecksumParsing.singleHash(in: response.text) { return hash }
        }
        for sums in ["SHA256SUMS", "sha256sums.txt", "CHECKSUMS.TXT", "checksums.txt"] {
            guard let sumsURL = url(named: sums),
                  let response = try? await http.data(from: sumsURL, headers: Self.apiHeaders),
                  response.isSuccess else { continue }
            if let line = ChecksumParsing.lines(in: response.text).first(where: { $0.fileName == name }) {
                return line.hash
            }
        }
        return nil
    }
}
