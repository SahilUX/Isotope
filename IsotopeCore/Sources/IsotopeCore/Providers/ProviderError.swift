import Foundation

/// Failures a version check can produce. Messages are user-facing (PRD F14/F25):
/// they say what was fetched and what did not match, so a bad regex in a custom
/// source is debuggable from the Test button alone (DESIGN §6).
public enum ProviderError: Error, LocalizedError, Equatable {
    case httpStatus(Int, URL)
    case invalidResponse(URL)
    case invalidRegex(String)
    /// The fetched document was retrieved fine but the pattern matched nothing.
    case noMatch(pattern: String, source: URL, snippet: String)
    case missingField(String, URL)
    case unusableURL(String)
    case unsupportedForMechanism(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let url):
            return "The source answered HTTP \(code) (\(url.absoluteString))."
        case .invalidResponse(let url):
            return "The response from \(url.absoluteString) was not valid HTTP."
        case .invalidRegex(let pattern):
            return "The pattern “\(pattern)” is not a valid regular expression."
        case .noMatch(let pattern, let source, let snippet):
            return "Nothing in \(source.absoluteString) matched “\(pattern)”. "
                + "The source starts with: \(snippet)"
        case .missingField(let field, let url):
            return "\(url.absoluteString) did not contain the expected field “\(field)”."
        case .unusableURL(let string):
            return "“\(string)” is not a usable URL."
        case .unsupportedForMechanism(let detail):
            return detail
        }
    }
}

extension ProviderError {
    /// First `limit` characters of a fetched document, whitespace-collapsed, for
    /// the "no match" message.
    static func snippet(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}
