import Foundation

/// Projects that publish a machine-readable release feed (Fedora's
/// `releases.json`, Pop!_OS's build API, Tails' `latest.json`). DESIGN §4.1 calls
/// for "a small dedicated parser, same protocol"; this is one parser driven by a
/// `JSONFeedSpec` of `JSONPath` expressions, so a new feed is catalog data rather
/// than new code.
public struct JSONFeedProvider: VersionProvider {
    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .jsonFeed(let url, let spec, let fileNamePattern) = config else {
            throw ProviderError.unsupportedForMechanism("JSONFeedProvider was given a \(config.mechanism.rawValue) config.")
        }
        let response = try await http.requireData(from: url)
        let root = try JSONSerialization.jsonObject(with: response.body,
                                                    options: [.fragmentsAllowed])

        let items = Self.items(in: root, spec: spec)
        // The recognition pattern doubles as a *selector* here: Fedora's feed
        // lists a DVD and a netinst under one (variant, subvariant, version), and
        // the filename is the only thing that tells them apart. Channels whose
        // filter is already exact carry a pattern that matches everything they
        // select, so this narrows nothing for them.
        let fileMatcher = fileNamePattern.flatMap { try? PatternMatcher($0, caseInsensitive: true) }
        var candidates: [VersionCandidate] = []
        for item in items {
            guard Self.passesFilter(item, spec.filter) else { continue }
            guard let raw = Self.versionString(item, keys: spec.versionKeys),
                  let version = VersionToken.parse(raw) else { continue }
            let isoURL = spec.isoURLKey.flatMap { JSONPath.string(item, at: $0) }.flatMap(URL.init(string:))
            let fileName = spec.fileNameKey.flatMap { JSONPath.string(item, at: $0) }
                ?? isoURL?.lastPathComponent ?? ""
            if let fileMatcher, !fileName.isEmpty, !fileMatcher.matchesAnywhere(fileName) { continue }
            candidates.append(VersionCandidate(
                version: version,
                fileName: fileName,
                sha256: spec.sha256Key.flatMap { JSONPath.string(item, at: $0) },
                url: isoURL,
                sizeBytes: spec.sizeKey.flatMap { JSONPath.int64(item, at: $0) }
            ))
        }

        guard let best = candidates.highest else {
            let described = spec.filter?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            throw ProviderError.noMatch(pattern: described ?? spec.versionKeys.joined(separator: "+"),
                                        source: url, snippet: ProviderError.snippet(response.text))
        }
        return Release(version: best.version, isoURL: best.url, fileName: best.fileName,
                       sha256: best.sha256, sizeBytes: best.sizeBytes)
    }

    private static func items(in root: Any, spec: JSONFeedSpec) -> [Any] {
        let node: Any? = (spec.itemsPath?.isEmpty == false)
            ? JSONPath.value(root, at: spec.itemsPath!)
            : root
        if let array = node as? [Any] { return array }
        // An object root is a single release (Pop!_OS returns exactly one build).
        if let object = node { return [object] }
        return []
    }

    private static func passesFilter(_ item: Any, _ filter: [String: String]?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return filter.allSatisfy { JSONPath.string(item, at: $0.key) == $0.value }
    }

    /// Several keys are joined with "." so a build number can extend a stable
    /// release number into something monotonic (Pop!_OS "24.04" + "20").
    private static func versionString(_ item: Any, keys: [String]) -> String? {
        let parts = keys.compactMap { JSONPath.string(item, at: $0) }
        guard parts.count == keys.count, !parts.isEmpty else { return nil }
        return parts.joined(separator: ".")
    }
}
