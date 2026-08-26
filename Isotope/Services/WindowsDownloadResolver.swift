import Foundation
import IsotopeCore

/// PRD F49: the opt-in attempt at getting a Windows ISO without the browser.
///
/// Microsoft's download page mints its links through two calls. The first —
/// which language SKUs exist for a product edition — answers any client
/// (`WindowsMediaCatalog`, PRD F48). The second, which turns a SKU into an
/// actual download URL, is behind an anti-automation check that answers
/// `"Sentinel marked this request as rejected"` to everything that does not
/// look like a browser session. Measured, not assumed: it refused a correctly
/// sequenced, correctly headed request from an ordinary residential address
/// during development.
///
/// So this is written as an *attempt*, off by default, whose failure path is
/// the normal one: the download page opens in the browser and the file the user
/// saves is verified and placed exactly as before. It succeeds only where
/// Microsoft chooses to answer, and it never becomes the reason an update is
/// impossible.
///
/// When it does succeed the response carries the ISO's SHA-256 alongside the
/// link, so a resolved download is verified like any other — an automatic
/// download that could not be checked would not be worth having.
protocol WindowsDownloadResolving: Sendable {
    func attempt(catalog: WindowsMediaCatalog, referer: URL) async -> WindowsDownloadAttempt
}

/// What actually happened, in enough detail to put on screen.
///
/// A bare "nil" was the original design and it was wrong for the one question
/// the user has: *is this thing working?* Silence cannot distinguish "Microsoft
/// refused" from "the setting is off" from "there is no network", and a feature
/// this likely to be refused has to be able to say which.
enum WindowsDownloadAttempt: Sendable, Equatable {
    /// Microsoft answered with a link. `sha256` may still be nil.
    case resolved(WindowsResolvedDownload)
    /// Microsoft answered, and said no. Carries their own words where they gave
    /// any — "Sentinel marked this request as rejected."
    case refused(String)
    /// Never got a usable answer: no network, a changed response shape, a
    /// non-2xx status.
    case failed(String)

    var download: WindowsResolvedDownload? {
        guard case .resolved(let download) = self else { return nil }
        return download
    }
}

struct WindowsResolvedDownload: Sendable, Hashable {
    var url: URL
    var fileName: String
    var sha256: String?
}

struct WindowsDownloadResolver: WindowsDownloadResolving {
    /// Microsoft's docs and download hosts reject some non-browser agents outright.
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
    ]
    /// The fingerprinting endpoint the page calls before asking for a link. The
    /// SKU call does not need it; the link call is likelier to be answered when
    /// the session has been seen there first.
    private static let sessionRegistrationURL = "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id="

    private let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func attempt(catalog: WindowsMediaCatalog, referer: URL) async -> WindowsDownloadAttempt {
        let sessionID = UUID().uuidString.lowercased()
        var headers = Self.headers
        headers["Referer"] = referer.absoluteString

        // 1 — let Microsoft see the session before it is used, as the page does.
        if let registration = URL(string: Self.sessionRegistrationURL + sessionID) {
            _ = try? await http.data(from: registration, headers: Self.headers)
        }

        // 2 — the SKU for the wanted language. This call is not the guarded
        //     one; if it fails, something else is wrong (usually the network).
        guard let skuURL = catalog.requestURL(sessionID: sessionID) else {
            return .failed("Isotope could not build the request URL for this entry.")
        }
        let skuResponse: HTTPResponse
        do {
            skuResponse = try await http.requireData(from: skuURL, headers: headers)
        } catch {
            return .failed("Could not reach Microsoft: \(error.localizedDescription)")
        }
        guard let skuID = Self.skuID(inResponse: skuResponse.body, language: catalog.language) else {
            return .failed("Microsoft's edition list did not contain a “\(catalog.language)” entry.")
        }

        // 3 — the link itself. This is the call that is usually refused.
        guard let linkURL = Self.downloadLinksURL(catalog: catalog, skuID: skuID, sessionID: sessionID) else {
            return .failed("Isotope could not build the download-link request.")
        }
        let response: HTTPResponse
        do {
            response = try await http.requireData(from: linkURL, headers: headers)
        } catch {
            return .failed("Microsoft did not answer the download-link request: \(error.localizedDescription)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) else {
            return .failed("Microsoft answered the download-link request with something that is not JSON.")
        }
        if let download = Self.download(in: root) { return .resolved(download) }
        return .refused(Self.refusal(in: root))
    }

    /// Microsoft's own words for the refusal, so the UI quotes rather than
    /// paraphrases. Falls back to a plain statement when the payload carries no
    /// message at all.
    static func refusal(in json: Any) -> String {
        guard let object = json as? [String: Any],
              let errors = object["Errors"] as? [[String: Any]] else {
            return "Microsoft answered without a download link."
        }
        let messages = errors.compactMap { error -> String? in
            (error["Value"] as? String) ?? (error["Key"] as? String)
        }
        guard !messages.isEmpty else { return "Microsoft answered without a download link." }
        return messages.joined(separator: " ")
    }

    // MARK: - Parsing

    static func skuID(inResponse data: Data, language: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skus = root["Skus"] as? [[String: Any]] else { return nil }
        let wanted = language.lowercased()
        let match = skus.first { ($0["Language"] as? String)?.lowercased() == wanted } ?? skus.first
        return match?["Id"] as? String
    }

    static func downloadLinksURL(catalog: WindowsMediaCatalog, skuID: String,
                                 sessionID: String) -> URL? {
        var components = URLComponents(url: catalog.url.appendingPathComponent("GetProductDownloadLinksBySku"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "profile", value: catalog.profile ?? WindowsMediaCatalog.defaultProfile),
            URLQueryItem(name: "ProductEditionId", value: "undefined"),
            URLQueryItem(name: "SKU", value: skuID),
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sdVersion", value: "2"),
            URLQueryItem(name: "sessionId", value: sessionID),
        ]
        return components?.url
    }

    /// The ISO link and its checksum, found by *shape* rather than by key name.
    ///
    /// The response is a JSON tree whose field names Microsoft has changed more
    /// than once. What does not change is what the values look like: an `https`
    /// URL ending in `.iso`, and a 64-character hex digest sitting in the same
    /// object. Walking for those survives a rename; hard-coding `Uri`/`Sha256`
    /// would not, and would fail silently the day it changed.
    ///
    /// A rejection payload (`{"Errors":[{"Key":"ErrorSettings.SentinelReject"…}]}`)
    /// contains neither, so it falls out as nil without special-casing.
    static func download(in json: Any) -> WindowsResolvedDownload? {
        var found: WindowsResolvedDownload?
        walk(json) { object in
            guard found == nil else { return }
            let strings = object.values.compactMap { $0 as? String }
            guard let link = strings.first(where: Self.isISOLink),
                  let url = URL(string: link) else { return }
            let digest = strings.first { ChecksumParsing.isSHA256($0.lowercased()) }
            found = WindowsResolvedDownload(url: url, fileName: url.lastPathComponent,
                                            sha256: digest?.lowercased())
        }
        return found
    }

    private static func isISOLink(_ candidate: String) -> Bool {
        guard candidate.lowercased().hasPrefix("https://"),
              let url = URL(string: candidate) else { return false }
        return url.lastPathComponent.lowercased().hasSuffix(".iso")
    }

    private static func walk(_ node: Any, visit: ([String: Any]) -> Void) {
        switch node {
        case let object as [String: Any]:
            visit(object)
            for value in object.values { walk(value, visit: visit) }
        case let array as [Any]:
            for value in array { walk(value, visit: visit) }
        default:
            break
        }
    }
}
