import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F73: `DownloadManager` probes a request's mirrors, downloads from the
/// winner, and never lets a bad mirror turn into a failed download.
///
/// The prober is a fake with canned timings and the transfers are served by a
/// `URLProtocol` stub, so nothing here touches the network.
final class MirrorSelectionTests: XCTestCase {
    private var root: URL!
    private var locations: CacheLocations!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeMirrorTests-\(UUID().uuidString)")
        locations = CacheLocations(root: root)
        try locations.ensureDirectoriesExist()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(prober: FakeProber, probesMirrors: Bool = true) -> DownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirrorStubProtocol.self]
        return DownloadManager(cache: ISOCache(locations: locations), locations: locations,
                               hashing: CryptoKitHashing(), maxConcurrent: 2,
                               sessionConfiguration: configuration,
                               prober: prober, probesMirrors: probesMirrors)
    }

    /// A unique file name per test, so the stub's visit log is per test.
    private func request(alternates hosts: [String]) -> ISORequest {
        let name = "image-\(UUID().uuidString).iso"
        return ISORequest(sourceURL: url("origin.test", name), fileName: name,
                          alternateURLs: hosts.map { url($0, name) })
    }

    private func url(_ host: String, _ name: String) -> URL {
        URL(string: "https://\(host)/pub/\(name)")!
    }

    /// A clean 206 for the whole (small) stub file in `seconds`.
    private func answered(_ url: URL, seconds: TimeInterval) -> MirrorProbeResult {
        let size = Int64(MirrorStubProtocol.bodyBytes)
        return MirrorProbeResult(url: url, statusCode: 206, contentRangeTotal: size,
                                 bytesReceived: size, elapsed: seconds)
    }

    // MARK: - Choosing

    func testDownloadsFromAClearlyFasterMirror() async throws {
        let request = request(alternates: ["fast.test"])
        let prober = FakeProber { urls in
            [self.answered(urls[0], seconds: 1.0), self.answered(urls[1], seconds: 0.1)]
        }
        let manager = makeManager(prober: prober)
        let stages = StageLog()

        let local = try await manager.ensureLocalISO(request) { stage, _ in stages.record(stage) }

        XCTAssertEqual(local.mirrorHost, "fast.test")
        XCTAssertEqual(MirrorStubProtocol.visits(for: request.fileName), ["fast.test"])
        XCTAssertEqual(prober.calls, [[request.sourceURL] + request.alternateURLs])
        XCTAssertEqual(stages.stages.first, .probing)
        // Cached under the catalog's URL, so the next lookup finds it.
        let hit = try await manager.ensureLocalISO(request) { _, _ in }
        XCTAssertEqual(hit.cacheKey, local.cacheKey)
        XCTAssertEqual(MirrorStubProtocol.visits(for: request.fileName).count, 1)
        await manager.endUse(cacheKey: local.cacheKey)
        await manager.endUse(cacheKey: hit.cacheKey)
    }

    func testFallsBackToTheOriginalWhenProbingFails() async throws {
        let request = request(alternates: ["fast.test"])
        let prober = FakeProber { urls in urls.map { MirrorProbeResult.failed($0, elapsed: 6) } }
        let manager = makeManager(prober: prober)

        let local = try await manager.ensureLocalISO(request) { _, _ in }

        XCTAssertNil(local.mirrorHost)
        XCTAssertEqual(MirrorStubProtocol.visits(for: request.fileName), ["origin.test"])
        await manager.endUse(cacheKey: local.cacheKey)
    }

    // MARK: - Not probing

    func testTheSettingTurnsProbingOff() async throws {
        let prober = FakeProber { urls in urls.map { self.answered($0, seconds: 0.1) } }
        let manager = makeManager(prober: prober, probesMirrors: false)
        let first = request(alternates: ["fast.test"])
        let local = try await manager.ensureLocalISO(first) { _, _ in }
        XCTAssertTrue(prober.calls.isEmpty)
        XCTAssertEqual(MirrorStubProtocol.visits(for: first.fileName), ["origin.test"])
        await manager.endUse(cacheKey: local.cacheKey)

        // And back on, through the setter Settings uses.
        await manager.setProbesMirrors(true)
        let second = request(alternates: ["fast.test"])
        let again = try await manager.ensureLocalISO(second) { _, _ in }
        XCTAssertEqual(prober.calls.count, 1)
        await manager.endUse(cacheKey: again.cacheKey)
    }

    func testNoAlternatesMeansNoProbe() async throws {
        let prober = FakeProber { urls in urls.map { self.answered($0, seconds: 0.1) } }
        let manager = makeManager(prober: prober)
        let request = request(alternates: [])
        let stages = StageLog()
        let local = try await manager.ensureLocalISO(request) { stage, _ in stages.record(stage) }
        XCTAssertTrue(prober.calls.isEmpty)
        XCTAssertFalse(stages.stages.contains(.probing))
        await manager.endUse(cacheKey: local.cacheKey)
    }

    func testAResumedDownloadSkipsProbing() async throws {
        // Resume data carries its own URL, so there is nothing to choose. (The
        // blob here is not real resume data; URLSession rejects it, which is
        // fine — the assertion is that no probe ran first.)
        let prober = FakeProber { urls in urls.map { self.answered($0, seconds: 0.1) } }
        let manager = makeManager(prober: prober)
        let request = request(alternates: ["fast.test"])
        try Data("not really resume data".utf8)
            .write(to: locations.resume.appendingPathComponent("\(request.cacheKey).resume"))

        _ = try? await manager.ensureLocalISO(request) { _, _ in }

        XCTAssertTrue(prober.calls.isEmpty)
        XCTAssertTrue(MirrorStubProtocol.visits(for: request.fileName).isEmpty)
    }

    // MARK: - Failing over

    func testARefusingMirrorFallsThroughToTheNextSource() async throws {
        let request = request(alternates: ["refuses.test"])
        // The probe liked it; by download time it answers 404.
        let prober = FakeProber { urls in
            [self.answered(urls[0], seconds: 1.0), self.answered(urls[1], seconds: 0.1)]
        }
        let manager = makeManager(prober: prober)

        let local = try await manager.ensureLocalISO(request) { _, _ in }

        XCTAssertNil(local.mirrorHost)
        XCTAssertEqual(MirrorStubProtocol.visits(for: request.fileName), ["refuses.test", "origin.test"])
        let manifest = JSONStore.load([InterruptedDownload].self, from: locations.resumeManifest,
                                      default: [])
        XCTAssertTrue(manifest.isEmpty, "a skipped mirror is not an interrupted download")
        await manager.endUse(cacheKey: local.cacheKey)
    }

    func testAMirrorThatDropsBeforeAnyByteFallsThrough() async throws {
        let request = request(alternates: ["drops.test", "fast.test"])
        let prober = FakeProber { urls in
            [self.answered(urls[0], seconds: 1.0), self.answered(urls[1], seconds: 0.1),
             self.answered(urls[2], seconds: 0.2)]
        }
        let manager = makeManager(prober: prober)

        let local = try await manager.ensureLocalISO(request) { _, _ in }

        XCTAssertEqual(local.mirrorHost, "fast.test")
        XCTAssertEqual(MirrorStubProtocol.visits(for: request.fileName), ["drops.test", "fast.test"])
        await manager.endUse(cacheKey: local.cacheKey)
    }

    func testTheLastSourcesFailureIsTheOneReported() async throws {
        // Only the original, and it refuses: that is a real failure.
        let name = "forbidden-\(UUID().uuidString).iso"
        let request = ISORequest(sourceURL: url("refuses.test", name), fileName: name,
                                 alternateURLs: [url("drops.test", name)])
        let prober = FakeProber { urls in
            [self.answered(urls[0], seconds: 0.1), self.answered(urls[1], seconds: 1.0)]
        }
        let manager = makeManager(prober: prober)
        do {
            _ = try await manager.ensureLocalISO(request) { _, _ in }
            XCTFail("both sources failed")
        } catch let error as DownloadError {
            guard case .transport = error else { return XCTFail("expected the last source's error, got \(error)") }
        }
        XCTAssertEqual(MirrorStubProtocol.visits(for: name), ["refuses.test", "drops.test"])
    }

    // MARK: - Cancel and pause during the probe

    func testCancelDuringTheProbeEndsTheDownloadAtOnce() async throws {
        let probing = expectation(description: "probe started")
        let prober = FakeProber(delay: .seconds(10), started: { probing.fulfill() }) { urls in
            urls.map { self.answered($0, seconds: 0.1) }
        }
        let manager = makeManager(prober: prober)
        let request = request(alternates: ["fast.test"])
        let run = Task { try await manager.ensureLocalISO(request) { _, _ in } }
        await fulfillment(of: [probing], timeout: 5)

        let started = ContinuousClock.now
        await manager.cancel(cacheKey: request.cacheKey)
        do {
            _ = try await run.value
            XCTFail("a cancelled download must not produce an ISO")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "cancel waited for the probe")
        XCTAssertTrue(MirrorStubProtocol.visits(for: request.fileName).isEmpty)
    }

    func testPauseDuringTheProbeParksAndResumeProbesAgain() async throws {
        let probing = expectation(description: "probe started")
        let gate = ProbeGate()
        let prober = FakeProber(delay: .seconds(10), started: {
            if gate.firstCall() { probing.fulfill() }
        }) { urls in
            [self.answered(urls[0], seconds: 1.0), self.answered(urls[1], seconds: 0.1)]
        }
        let manager = makeManager(prober: prober)
        let request = request(alternates: ["fast.test"])
        let run = Task { try await manager.ensureLocalISO(request) { _, _ in } }
        await fulfillment(of: [probing], timeout: 5)

        await manager.pause(cacheKey: request.cacheKey)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(MirrorStubProtocol.visits(for: request.fileName).isEmpty,
                      "paused before anything was chosen, so nothing downloads")

        prober.delay = .zero
        await manager.resume(cacheKey: request.cacheKey)
        let local = try await run.value
        XCTAssertEqual(prober.calls.count, 2)
        XCTAssertEqual(local.mirrorHost, "fast.test")
        await manager.endUse(cacheKey: local.cacheKey)
    }

    // MARK: - Where alternates come from

    @MainActor
    func testTheStoreExpandsAnEntrysMirrorRules() {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let iso = URL(string: "https://releases.example/26.04/x.iso")!
        store.addCustomEntry(CatalogEntry(
            id: "custom-x", name: "X", kind: .custom,
            channels: [Channel(id: "default", name: "Default",
                               provider: .staticURL(url: iso, checksumURL: nil))],
            isBuiltIn: false,
            mirrors: [MirrorRule(from: "https://releases.example/",
                                 to: ["https://mirror.example/x-releases/"])]))
        XCTAssertEqual(store.mirrorAlternates(entryID: "custom-x", channelID: "default", for: iso),
                       [URL(string: "https://mirror.example/x-releases/26.04/x.iso")!])
        XCTAssertEqual(store.mirrorAlternates(entryID: "missing", channelID: "default", for: iso), [])
        // The cache key is the catalog URL's, whatever the alternates.
        let plain = ISORequest(sourceURL: iso, fileName: "x.iso")
        var mirrored = plain
        mirrored.alternateURLs = store.mirrorAlternates(entryID: "custom-x", channelID: "default", for: iso)
        XCTAssertEqual(plain.cacheKey, mirrored.cacheKey)
    }
}

// MARK: - Fakes

/// Canned probe results, with an optional delay that honours cancellation the
/// way the real prober does.
private final class FakeProber: MirrorProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[URL]] = []
    private var _delay: Duration
    private let started: @Sendable () -> Void
    private let answer: @Sendable ([URL]) -> [MirrorProbeResult]

    init(delay: Duration = .zero, started: @escaping @Sendable () -> Void = {},
         answer: @escaping @Sendable ([URL]) -> [MirrorProbeResult]) {
        self._delay = delay
        self.started = started
        self.answer = answer
    }

    var calls: [[URL]] { lock.withLock { _calls } }
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    func probe(_ urls: [URL]) async -> [MirrorProbeResult] {
        let delay = lock.withLock { () -> Duration in
            _calls.append(urls)
            return _delay
        }
        started()
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return [] }
        }
        return answer(urls)
    }
}

private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func firstCall() -> Bool { lock.withLock { calls += 1; return calls == 1 } }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [DownloadStage] = []
    var stages: [DownloadStage] { lock.withLock { _stages } }
    func record(_ stage: DownloadStage) { lock.withLock { _stages.append(stage) } }
}

/// Serves a small file from `origin.test` and `fast.test`, a 404 from
/// `refuses.test`, and a dropped connection with no response from
/// `drops.test`. Every request is logged by file name, so each test can see
/// which servers it actually downloaded from.
final class MirrorStubProtocol: URLProtocol, @unchecked Sendable {
    static let bodyBytes = 64 * 1024
    private static let lock = NSLock()
    private static var log: [String: [String]] = [:]

    static func visits(for fileName: String) -> [String] {
        lock.withLock { log[fileName] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["origin.test", "fast.test", "refuses.test", "drops.test"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.withLock { Self.log[url.lastPathComponent, default: []].append(host) }
        switch host {
        case "drops.test":
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case "refuses.test":
            let refusal = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: refusal, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<h1>404 Not Found</h1>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(Self.bodyBytes)",
                                                          "Accept-Ranges": "bytes"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x42, count: Self.bodyBytes))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
