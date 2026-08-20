import Foundation

/// PRD §5.3 — constant URL + change detection. A `HEAD` request yields
/// `Last-Modified` / `ETag` / `Content-Length`; there is no semantic version, so
/// the version is the change date and the raw string is the signature the UI shows.
///
/// When the server sends no `Last-Modified`, the change date is "now" and the raw
/// signature is the ETag (or size). Callers must therefore keep the previously
/// cached date when the signature is unchanged — `CatalogService` does this via
/// `Release.carryingOverChangeDate(from:)`; without it every check would look new.
public struct StaticURLProvider: VersionProvider {
    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetchLatest(config: ProviderConfig) async throws -> Release {
        guard case .staticURL(let url, let checksumURL, _) = config else {
            throw ProviderError.unsupportedForMechanism("StaticURLProvider was given a \(config.mechanism.rawValue) config.")
        }
        let response = try await http.head(for: url)
        guard response.isSuccess else { throw ProviderError.httpStatus(response.statusCode, url) }

        let size = contentLength(response)
        let (date, raw) = changeSignature(response, size: size)

        var sha: String?
        if let checksumURL, let sums = try? await http.data(from: checksumURL), sums.isSuccess {
            let fileName = url.lastPathComponent
            sha = ChecksumParsing.lines(in: sums.text).first { $0.fileName == fileName }?.hash
                ?? ChecksumParsing.singleHash(in: sums.text)
        }

        return Release(version: .date(date, raw: raw), isoURL: url,
                       fileName: url.lastPathComponent, sha256: sha, sizeBytes: size)
    }

    private func contentLength(_ response: HTTPResponse) -> Int64? {
        // A ranged fallback GET reports Content-Range, not the full Content-Length.
        if let range = response.header("Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total) {
            return value
        }
        return response.header("Content-Length").flatMap(Int64.init)
    }

    private func changeSignature(_ response: HTTPResponse, size: Int64?) -> (Date, String) {
        if let lastModified = response.header("Last-Modified"),
           let date = Self.httpDateFormatter.date(from: lastModified) {
            return (date, Self.displayFormatter.string(from: date))
        }
        if let etag = response.header("ETag") {
            return (Date(), etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ ")))
        }
        return (Date(), size.map { "\($0) bytes" } ?? "unknown")
    }

    /// RFC 7231 IMF-fixdate; forced to POSIX/GMT so the parse is locale-independent.
    static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public extension Release {
    /// PRD §5.3/F15: change-detection sources have no ordering of their own. If
    /// the signature is unchanged since the last check, keep the old change date
    /// so the release does not appear newer than what is installed.
    func carryingOverChangeDate(from previous: Release?) -> Release {
        guard case .date(_, let raw) = version,
              let previous, case .date(let oldDate, let oldRaw) = previous.version,
              oldRaw == raw else { return self }
        var copy = self
        copy.version = .date(oldDate, raw: raw)
        return copy
    }
}
