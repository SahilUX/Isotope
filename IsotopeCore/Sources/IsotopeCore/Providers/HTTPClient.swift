import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP response reduced to what the providers need. Keeping this a plain
/// value type (rather than `URLResponse`) is what lets the whole provider layer
/// be unit-tested offline and compiled on Linux.
public struct HTTPResponse: Sendable {
    public var url: URL
    public var statusCode: Int
    /// Header names are lowercased on construction so lookups are case-insensitive.
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) },
                                  uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Decodes as UTF-8, falling back to ISO Latin-1 so a stray byte in a
    /// checksum file or HTML page never fails the whole check.
    public var text: String {
        String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? ""
    }
}

public protocol HTTPClient: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> HTTPResponse
    func head(for url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public extension HTTPClient {
    func data(from url: URL) async throws -> HTTPResponse { try await data(from: url, headers: [:]) }
    func head(for url: URL) async throws -> HTTPResponse { try await head(for: url, headers: [:]) }

    /// GET that turns a non-2xx status into a typed error.
    func requireData(from url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let response = try await data(from: url, headers: headers)
        guard response.isSuccess else { throw ProviderError.httpStatus(response.statusCode, url) }
        return response
    }
}

/// Default client. PRD N5: individual source timeout 15 s.
public struct URLSessionHTTPClient: HTTPClient {
    public static let defaultTimeout: TimeInterval = 15
    public static let userAgent = "Isotope/0.1 (+https://github.com/isotope-app)"

    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = URLSessionHTTPClient.defaultTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": URLSessionHTTPClient.userAgent]
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func data(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await perform(url: url, method: "GET", headers: headers)
    }

    public func head(for url: URL, headers: [String: String]) async throws -> HTTPResponse {
        // Some CDNs answer HEAD with 405; fall back to a ranged GET that fetches
        // one byte so ETag/Last-Modified/Content-Length are still observable.
        let response = try await perform(url: url, method: "HEAD", headers: headers)
        if response.statusCode == 405 || response.statusCode == 501 {
            var ranged = headers
            ranged["Range"] = "bytes=0-0"
            return try await perform(url: url, method: "GET", headers: ranged)
        }
        return response
    }

    private func perform(url: URL, method: String, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(url)
        }
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headerFields[key] = value }
        }
        return HTTPResponse(url: http.url ?? url, statusCode: http.statusCode,
                            headers: headerFields, body: data)
    }
}
