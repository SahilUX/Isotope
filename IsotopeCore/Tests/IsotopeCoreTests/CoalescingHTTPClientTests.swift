import XCTest
@testable import IsotopeCore

/// PRD F50: several channels legitimately want the same URL during one check.
/// They should cost one request, not one each — the catalog has 24 Ubuntu-family
/// channels behind two index files and 16 Fedora channels behind one feed, and
/// the duplicate requests are what earned an HTTP 429 from
/// `changelogs.ubuntu.com` in the first place.
final class CoalescingHTTPClientTests: XCTestCase {
    private let url = URL(string: "https://changelogs.invalid/meta-release")!

    /// Counts what actually reached the network, and can be told to answer
    /// slowly so a real fan-out overlaps.
    private final class CountingClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private let delay: TimeInterval
        private let statusCode: Int

        init(delay: TimeInterval = 0, statusCode: Int = 200) {
            self.delay = delay
            self.statusCode = statusCode
        }

        var calls: Int { lock.withLock { _calls } }

        func data(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
            lock.withLock { _calls += 1 }
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return HTTPResponse(url: url, statusCode: statusCode, body: Data("Version: 26.04".utf8))
        }

        func head(for url: URL, headers: [String: String]) async throws -> HTTPResponse {
            lock.withLock { _calls += 1 }
            return HTTPResponse(url: url, statusCode: statusCode)
        }
    }

    func testAFanOutOfIdenticalRequestsCostsOne() async throws {
        let counting = CountingClient(delay: 0.05)
        let client = CoalescingHTTPClient(wrapping: counting)

        // The shape of a real check: every Ubuntu flavour at once.
        try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            for _ in 0..<24 {
                group.addTask { try await client.data(from: self.url, headers: [:]) }
            }
            var received = 0
            for try await response in group {
                XCTAssertEqual(response.text, "Version: 26.04")
                received += 1
            }
            XCTAssertEqual(received, 24)
        }
        XCTAssertEqual(counting.calls, 1)
    }

    func testASecondCheckWithinTheWindowIsServedFromTheAnswerAlreadyGiven() async throws {
        let counting = CountingClient()
        let client = CoalescingHTTPClient(wrapping: counting)
        _ = try await client.data(from: url, headers: [:])
        _ = try await client.data(from: url, headers: [:])
        XCTAssertEqual(counting.calls, 1)
    }

    func testTheWindowExpires() async throws {
        let counting = CountingClient()
        let client = CoalescingHTTPClient(wrapping: counting, ttl: 0.05)
        _ = try await client.data(from: url, headers: [:])
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await client.data(from: url, headers: [:])
        XCTAssertEqual(counting.calls, 2)
    }

    func testAFailureIsNeverRemembered() async throws {
        // The whole point: one 429 must not be handed to twenty other channels,
        // and the next attempt has to be a real attempt.
        let counting = CountingClient(statusCode: 429)
        let client = CoalescingHTTPClient(wrapping: counting)
        let first = try await client.data(from: url, headers: [:])
        XCTAssertEqual(first.statusCode, 429)
        _ = try await client.data(from: url, headers: [:])
        XCTAssertEqual(counting.calls, 2)
    }

    func testDifferentHeadersAreDifferentRequests() async throws {
        // GitHub and Microsoft are asked with their own headers; conflating them
        // would serve one API's answer to the other.
        let counting = CountingClient()
        let client = CoalescingHTTPClient(wrapping: counting)
        _ = try await client.data(from: url, headers: ["Accept": "application/json"])
        _ = try await client.data(from: url, headers: ["Accept": "text/html"])
        XCTAssertEqual(counting.calls, 2)
    }

    func testAHeadIsNotAnswerdByAGet() async throws {
        let counting = CountingClient()
        let client = CoalescingHTTPClient(wrapping: counting)
        _ = try await client.data(from: url, headers: [:])
        _ = try await client.head(for: url, headers: [:])
        XCTAssertEqual(counting.calls, 2)
    }

    func testResetMakesTheNextCheckHitTheNetwork() async throws {
        let counting = CountingClient()
        let client = CoalescingHTTPClient(wrapping: counting)
        _ = try await client.data(from: url, headers: [:])
        await client.reset()
        _ = try await client.data(from: url, headers: [:])
        XCTAssertEqual(counting.calls, 2)
    }

    func testTheResolverCanBeAskedNotToCoalesce() {
        // Provider tests count requests through their own fake and need every
        // one of them to arrive.
        let mock = MockHTTPClient()
        XCTAssertTrue(VersionResolver(http: mock, coalescing: false).http is MockHTTPClient)
        XCTAssertTrue(VersionResolver(http: mock).http is CoalescingHTTPClient)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
