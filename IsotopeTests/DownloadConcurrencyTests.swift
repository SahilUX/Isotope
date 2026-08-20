import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F19: max-2 concurrent downloads, pausable. A paused download must give
/// its slot back — otherwise two paused downloads wedge the queue and nothing
/// else ever starts.
///
/// The transfers are served by a `URLProtocol` stub, so the test needs no
/// network and finishes in well under a second.
final class DownloadConcurrencyTests: XCTestCase {
    private var root: URL!
    private var locations: CacheLocations!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeConcurrencyTests-\(UUID().uuidString)")
        locations = CacheLocations(root: root)
        try locations.ensureDirectoriesExist()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(maxConcurrent: Int) -> DownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrickleProtocol.self]
        return DownloadManager(cache: ISOCache(locations: locations), locations: locations,
                               hashing: CryptoKitHashing(), maxConcurrent: maxConcurrent,
                               sessionConfiguration: configuration)
    }

    private func request(_ name: String) -> ISORequest {
        ISORequest(sourceURL: URL(string: "https://downloads.test/\(name)")!, fileName: name)
    }

    func testAPausedDownloadFreesItsSlotForQueuedWork() async throws {
        let manager = makeManager(maxConcurrent: 1)
        let first = request("first.iso")
        let started = expectation(description: "first download is transferring")
        let firstProgressed = OneShot(started)

        let firstRun = Task {
            _ = try? await manager.ensureLocalISO(first) { _, progress in
                if progress.completedBytes > 0 { firstProgressed.fire() }
            }
        }
        await fulfillment(of: [started], timeout: 5)

        // The only slot is now held by `first`; parking it must hand the slot on.
        await manager.pause(cacheKey: first.cacheKey)

        let second = request("second.iso")
        let local = try await withThrowingTaskGroup(of: LocalISO.self) { group -> LocalISO in
            group.addTask { try await manager.ensureLocalISO(second) { _, _ in } }
            group.addTask {
                try await Task.sleep(nanoseconds: 10 * NSEC_PER_SEC)
                throw StuckQueue()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        XCTAssertEqual(local.sizeBytes, Int64(TrickleProtocol.totalBytes))

        await manager.cancel(cacheKey: first.cacheKey)
        await manager.endUse(cacheKey: local.cacheKey)
        _ = await firstRun.result
    }

    /// Resuming a parked download takes a slot again, and it runs to completion.
    func testAResumedDownloadReacquiresASlotAndFinishes() async throws {
        let manager = makeManager(maxConcurrent: 1)
        let first = request("resumable.iso")
        let started = expectation(description: "download is transferring")
        let progressed = OneShot(started)

        let run = Task { try await manager.ensureLocalISO(first) { _, progress in
            if progress.completedBytes > 0 { progressed.fire() }
        } }
        await fulfillment(of: [started], timeout: 5)
        await manager.pause(cacheKey: first.cacheKey)
        // Nothing else is queued, so the slot is simply free again.
        await manager.resume(cacheKey: first.cacheKey)

        let local = try await run.value
        XCTAssertEqual(local.sizeBytes, Int64(TrickleProtocol.totalBytes))
        await manager.endUse(cacheKey: local.cacheKey)
    }

    /// A quit while a download is in flight records it as resumable (PRD F19).
    func testQuitRecordsInFlightDownloadsAsResumable() async throws {
        let manager = makeManager(maxConcurrent: 2)
        let first = request("quitting.iso")
        let started = expectation(description: "download is transferring")
        let progressed = OneShot(started)
        let run = Task {
            _ = try? await manager.ensureLocalISO(first) { _, progress in
                if progress.completedBytes > 0 { progressed.fire() }
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let parked = await manager.suspendForQuit()
        XCTAssertEqual(parked, [first.cacheKey])

        // The manifest is what a relaunch reads. (Whether `URLSession` hands
        // back resume data is up to it — the stub protocol produces none — so
        // the assertion is on the record, not on the resume file.)
        let manifest = try XCTUnwrap(JSONStore.load([InterruptedDownload].self,
                                                    from: locations.resumeManifest))
        XCTAssertEqual(manifest.map(\.id), [first.cacheKey])
        XCTAssertTrue(manifest[0].wasPaused)
        XCTAssertEqual(manifest[0].fileName, "quitting.iso")

        await manager.cancel(cacheKey: first.cacheKey)
        _ = await run.result
    }
}

private struct StuckQueue: Error {}

/// Fires an expectation exactly once from any thread.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) { self.expectation = expectation }

    func fire() {
        let shouldFire: Bool = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        if shouldFire { expectation.fulfill() }
    }
}

/// Serves a fixed-size body in small chunks with a short gap between them, so a
/// download is reliably still in flight when the test pauses it.
final class TrickleProtocol: URLProtocol, @unchecked Sendable {
    static let totalBytes = 256 * 1024
    static let chunkBytes = 8 * 1024
    private var stopped = false
    private let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "downloads.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "\(Self.totalBytes)",
                                                            "Accept-Ranges": "bytes"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 0x5A, count: Self.chunkBytes)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var sent = 0
            while sent < Self.totalBytes {
                if self.lock.withLock({ self.stopped }) { return }
                self.client?.urlProtocol(self, didLoad: chunk)
                sent += chunk.count
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !self.lock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }
}
