import Foundation

/// PRD F50: one GET per URL per check, however many channels want it.
///
/// A catalog check fans out across every channel at once, and the catalog is
/// full of URLs that several channels share: 24 Ubuntu-family channels resolve
/// their series from the same two `changelogs.ubuntu.com` files, 16 Fedora
/// channels read one `releases.json`, Kali's five images and Debian Live's six
/// each come from a single `SHA256SUMS`. Issuing those requests once per
/// channel is not just wasteful — `changelogs.ubuntu.com` answers 429 to the
/// stampede, and the flavours fail a check that nothing is actually wrong with.
///
/// This wraps any `HTTPClient` and does two things:
///
/// * **Coalesces in-flight requests.** A second request for a URL another is
///   already waiting on joins that one instead of starting its own.
/// * **Remembers the answer briefly.** `ttl` seconds, enough to cover a check
///   that fans out in waves rather than all at once, and far too short to
///   serve a stale release: a check that runs every six hours never sees it.
///
/// Failures are never remembered. A 429 or a timeout must not be handed to
/// twenty other channels, and a retry a second later has to be a real retry.
public actor CoalescingHTTPClient: HTTPClient {
    /// Long enough to cover one check's fan-out, short enough that no user-
    /// visible "check now" ever answers out of it twice.
    public static let defaultTTL: TimeInterval = 120

    private struct Key: Hashable {
        let method: String
        let url: URL
        let headers: [String: String]
    }

    private let underlying: HTTPClient
    private let ttl: TimeInterval
    private var inFlight: [Key: Task<HTTPResponse, Error>] = [:]
    private var recent: [Key: (response: HTTPResponse, at: Date)] = [:]

    public init(wrapping underlying: HTTPClient, ttl: TimeInterval = CoalescingHTTPClient.defaultTTL) {
        self.underlying = underlying
        self.ttl = ttl
    }

    public func data(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await perform(Key(method: "GET", url: url, headers: headers)) { [underlying] in
            try await underlying.data(from: url, headers: headers)
        }
    }

    public func head(for url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await perform(Key(method: "HEAD", url: url, headers: headers)) { [underlying] in
            try await underlying.head(for: url, headers: headers)
        }
    }

    /// Drops everything remembered. The app calls this when the user asks for a
    /// check by hand, so "Check Now" always means the network.
    public func reset() {
        recent.removeAll()
    }

    private func perform(_ key: Key,
                         _ request: @escaping @Sendable () async throws -> HTTPResponse)
        async throws -> HTTPResponse {
        if let cached = recent[key], Date().timeIntervalSince(cached.at) < ttl {
            return cached.response
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await request() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let response = try await task.value
        // Only a real answer is worth remembering — and only a successful one.
        // A 429 cached for two minutes would turn one rate-limited request into
        // twenty failed channels, which is the bug this exists to fix.
        if response.isSuccess { recent[key] = (response, Date()) }
        return response
    }
}
