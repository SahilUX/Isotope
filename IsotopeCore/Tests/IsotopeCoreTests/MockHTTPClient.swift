import Foundation
import XCTest
@testable import IsotopeCore

/// Offline stand-in for `URLSessionHTTPClient`: every provider test is served
/// from bundled fixtures, so the suite is CI-safe (DESIGN §7).
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let lock = NSLock()
    private var stubs: [String: Stub] = [:]
    private(set) var requestedGETs: [URL] = []
    private(set) var requestedHEADs: [URL] = []
    private(set) var lastHeaders: [String: String] = [:]

    func stub(_ url: String, text: String, statusCode: Int = 200, headers: [String: String] = [:]) {
        stubs[url] = Stub(statusCode: statusCode, headers: headers, body: Data(text.utf8))
    }

    func stub(_ url: String, fixture name: String, statusCode: Int = 200) {
        stub(url, text: Fixtures.text(name), statusCode: statusCode)
    }

    func stubHead(_ url: String, headers: [String: String], statusCode: Int = 200) {
        stubs[url] = Stub(statusCode: statusCode, headers: headers, body: Data())
    }

    func data(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.lock(); requestedGETs.append(url); lastHeaders = headers; lock.unlock()
        return response(for: url)
    }

    func head(for url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.lock(); requestedHEADs.append(url); lastHeaders = headers; lock.unlock()
        return response(for: url)
    }

    private func response(for url: URL) -> HTTPResponse {
        guard let stub = stubs[url.absoluteString] else {
            return HTTPResponse(url: url, statusCode: 404, body: Data("not stubbed".utf8))
        }
        return HTTPResponse(url: url, statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
    }
}

enum Fixtures {
    static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Missing fixture \(name)")
            return ""
        }
        return text
    }
}
