import Foundation

/// PRD F48: which *issue* of a Windows feature release a file is.
///
/// Microsoft reissues the media for a release without changing the release:
/// 25H2 has shipped as the original media and again as "V2". The reissue is the
/// only Windows update that can actually be acted on — a newer servicing build
/// (F46) usually cannot be downloaded at all, but a new media revision means
/// there is genuinely a new ISO on the download page.
///
/// Two independent sources name it, which is what makes the comparison honest:
///
/// * Microsoft's download-connector API returns `ProductDisplayName`, e.g.
///   `Windows 11 25H2__V2` or `Windows 10 22H2_v1`.
/// * The media filename carries it: `Win11_25H2_English_x64v2.iso`, with the
///   original issue simply having no suffix.
public enum WindowsMediaName {
    /// The original media of a release carries no suffix at all; it is issue 1,
    /// not "unknown". Saying so is what lets an un-suffixed ISO be compared
    /// against a `__V2` on the download page.
    public static let firstRevision = 1

    /// `Windows 11 25H2__V2` → (25H2, 2); `Windows 10 22H2_v1` → (22H2, 1);
    /// `Windows 11 24H2` → (24H2, 1).
    ///
    /// The separator varies between products (`__V` on Windows 11, `_v` on
    /// Windows 10) and the case of the "v" with it, so both are accepted. Nil
    /// when there is no feature release in the name at all, because a revision
    /// without the release it belongs to compares against nothing.
    public static func identity(productDisplayName: String) -> (release: VersionToken, revision: Int)? {
        // No trailing \b: an underscore is a word character, so "25H2__V2"
        // would have no boundary after the release and would not match at all.
        guard let matcher = try? PatternMatcher(#"(?<![0-9A-Za-z])(\d{2}H\d)(?:_{1,2}[vV](\d+))?"#),
              let groups = matcher.firstMatch(in: productDisplayName),
              let release = VersionToken.parse(groups[1])
        else { return nil }
        let revision = groups.count > 2 ? Int(groups[2]) ?? firstRevision : firstRevision
        return (release, revision)
    }

    /// The issue a piece of Microsoft media claims by its filename:
    /// `Win11_25H2_English_x64v2.iso` → 2, `Win11_25H2_English_x64.iso` → 1.
    ///
    /// Nil for anything that is not recognisably Microsoft's own media naming —
    /// a renamed or third-party file says nothing about its issue, and guessing
    /// 1 for it would invent an update the moment Microsoft shipped a V2.
    public static func revision(fromFileName fileName: String) -> Int? {
        guard let matcher = try? PatternMatcher(
            #"^Win(?:10|11)_.*_(?:x64|x86|x32|arm64)(?:_?[vV](\d+))?\.iso$"#, caseInsensitive: true),
              let groups = matcher.firstMatch(in: fileName)
        else { return nil }
        guard groups.count > 1, !groups[1].isEmpty else { return firstRevision }
        return Int(groups[1]) ?? firstRevision
    }

    /// "v2" for display beside the release; nil for the original issue, which
    /// is written without a suffix everywhere Microsoft writes it.
    public static func displaySuffix(revision: Int?) -> String? {
        guard let revision, revision > firstRevision else { return nil }
        return "v\(revision)"
    }
}

/// PRD F48: where a Windows entry asks Microsoft what it is currently serving.
///
/// `getskuinformationbyproductedition` answers with the language list for a
/// product edition, each entry carrying the `ProductDisplayName` that names the
/// release and its media revision. It needs no session registration, no
/// fingerprint and no login — one plain GET with a random session id.
///
/// The sibling call that mints an actual download link is refused for anything
/// that is not a browser ("Sentinel marked this request as rejected"), which is
/// exactly why Isotope reads what Microsoft is serving here and still hands the
/// download itself to the browser (PRD §5.4).
public struct WindowsMediaCatalog: Codable, Hashable, Sendable {
    /// API root, e.g. `https://www.microsoft.com/software-download-connector/api`.
    public var url: URL
    /// The product edition, as the download page's own `<option value>`:
    /// 3321 for Windows 11, 2618 for Windows 10. Data, because Microsoft
    /// renumbers it with every feature release.
    public var productEditionID: String
    /// Which language's entry to read the display name from. Every language
    /// carries the same release and revision; "English" is simply the one that
    /// is always present.
    public var language: String
    /// The opaque `profile` constant the page sends. Optional so a change to it
    /// is a catalog edit.
    public var profile: String?

    public init(url: URL, productEditionID: String, language: String = "English",
                profile: String? = nil) {
        self.url = url
        self.productEditionID = productEditionID
        self.language = language
        self.profile = profile
    }

    public static let defaultProfile = "606624d44113"

    /// The full request, including a fresh session id. The id is only an opaque
    /// correlation token for Microsoft's side; a new one per request is what a
    /// first visit to the page looks like.
    public func requestURL(sessionID: String) -> URL? {
        var components = URLComponents(url: url.appendingPathComponent("getskuinformationbyproductedition"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "profile", value: profile ?? Self.defaultProfile),
            URLQueryItem(name: "ProductEditionId", value: productEditionID),
            URLQueryItem(name: "SKU", value: "undefined"),
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sdVersion", value: "2"),
            URLQueryItem(name: "sessionId", value: sessionID),
        ]
        return components?.url
    }

    /// The release and revision in a SKU response, from the first entry whose
    /// language matches. Nil for an error payload, an unparsable body, or a
    /// display name with no feature release in it — all of which mean "keep the
    /// release the download page already gave us".
    public func identity(inSKUResponse data: Data) -> (release: VersionToken, revision: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skus = root["Skus"] as? [[String: Any]]
        else { return nil }
        let wanted = language.lowercased()
        let match = skus.first { ($0["Language"] as? String)?.lowercased() == wanted } ?? skus.first
        guard let name = match?["ProductDisplayName"] as? String else { return nil }
        return WindowsMediaName.identity(productDisplayName: name)
    }
}
