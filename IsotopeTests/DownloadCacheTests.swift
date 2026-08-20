import IsotopeCore
import XCTest
@testable import Isotope

/// The disk half of the cache and the cache-hit path through `DownloadManager`
/// (PRD F20). No network: a hit must never reach `URLSession`, which is exactly
/// what makes this testable offline.
final class DownloadCacheTests: XCTestCase {
    private var root: URL!
    private var locations: CacheLocations!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCacheTests-\(UUID().uuidString)")
        locations = CacheLocations(root: root)
        try locations.ensureDirectoriesExist()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scratchFile(_ name: String, size: Int = 4096) throws -> URL {
        try TestFiles.write(root.appendingPathComponent("scratch").appendingPathComponent(name), size: size)
    }

    // MARK: - ISOCache

    func testAdoptedFileIsFoundAgainByChecksum() async throws {
        let cache = ISOCache(locations: locations)
        let source = try scratchFile("ubuntu.iso")
        let artifact = try await cache.adopt(fileAt: source, key: "sha256-aa",
                                             fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                             sha256: "AA", sourceURL: URL(string: "https://a/x.iso"))
        XCTAssertEqual(artifact.sizeBytes, 4096)
        // The download's temp file was moved, not copied.
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let hit = await cache.hit(sourceURL: URL(string: "https://mirror/x.iso"), sha256: "aa")
        XCTAssertEqual(hit?.key, "sha256-aa")
        let hitURL = await cache.fileURL(hit!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hitURL.path))
    }

    func testAMissingCacheFileSelfHealsIntoAMiss() async throws {
        let cache = ISOCache(locations: locations)
        let artifact = try await cache.adopt(fileAt: try scratchFile("a.iso"), key: "sha256-bb",
                                             fileName: "a.iso", sha256: "bb", sourceURL: nil)
        // macOS purged Caches, or the user emptied it by hand.
        try FileManager.default.removeItem(at: await cache.fileURL(artifact))

        let hit = await cache.hit(sourceURL: nil, sha256: "bb")
        XCTAssertNil(hit)
        let snapshot = await cache.snapshot
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testCapacityChangeEvictsAndClearReclaims() async throws {
        let cache = ISOCache(locations: locations)
        _ = try await cache.adopt(fileAt: try scratchFile("a.iso", size: 8192), key: "a",
                                  fileName: "a.iso", sha256: "a", sourceURL: nil,
                                  at: Date(timeIntervalSince1970: 1))
        _ = try await cache.adopt(fileAt: try scratchFile("b.iso", size: 8192), key: "b",
                                  fileName: "b.iso", sha256: "b", sourceURL: nil,
                                  at: Date(timeIntervalSince1970: 2))
        var total = await cache.totalBytes
        XCTAssertEqual(total, 16384)

        await cache.setCapacity(8192)
        total = await cache.totalBytes
        XCTAssertEqual(total, 8192)
        let evicted = await cache.artifact(key: "a")
        XCTAssertNil(evicted)                            // the older one went

        let freed = await cache.clear()
        XCTAssertEqual(freed, 8192)
        total = await cache.totalBytes
        XCTAssertEqual(total, 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: locations.isos.path)
        XCTAssertEqual(remaining, [])
    }

    func testHeldArtifactsSurviveAClear() async throws {
        let cache = ISOCache(locations: locations)
        _ = try await cache.adopt(fileAt: try scratchFile("a.iso"), key: "a", fileName: "a.iso",
                                  sha256: "a", sourceURL: nil)
        await cache.retain(key: "a")
        var freed = await cache.clear()
        XCTAssertEqual(freed, 0)
        let held = await cache.artifact(key: "a")
        XCTAssertNotNil(held)
        await cache.release(key: "a")
        freed = await cache.clear()
        XCTAssertGreaterThan(freed, 0)
    }

    func testIndexSurvivesARelaunch() async throws {
        let first = ISOCache(locations: locations)
        _ = try await first.adopt(fileAt: try scratchFile("a.iso"), key: "sha256-cc",
                                  fileName: "a.iso", sha256: "cc", sourceURL: nil)
        let second = ISOCache(locations: locations)
        let hit = await second.hit(sourceURL: nil, sha256: "cc")
        XCTAssertNotNil(hit)
    }

    // MARK: - DownloadManager cache hit (PRD F20)

    func testCacheHitSkipsTheNetworkEntirely() async throws {
        let cache = ISOCache(locations: locations)
        _ = try await cache.adopt(fileAt: try scratchFile("ubuntu.iso", size: 2048),
                                  key: "sha256-dd", fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                  sha256: "dd",
                                  sourceURL: URL(string: "https://example.test/ubuntu.iso"))
        // A configuration with no allowed networking at all: if the manager
        // tried to download, this test would fail rather than hang forever.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let manager = DownloadManager(cache: cache, locations: locations, hashing: CryptoKitHashing(),
                                      sessionConfiguration: configuration)

        let stages = StageRecorder()
        let request = ISORequest(sourceURL: URL(string: "https://example.test/ubuntu.iso")!,
                                 fileName: "ubuntu-24.04.4-desktop-amd64.iso", sha256: "DD")
        let local = try await manager.ensureLocalISO(request) { stage, _ in stages.record(stage) }

        XCTAssertEqual(stages.stages, [.cached])
        XCTAssertEqual(local.sizeBytes, 2048)
        XCTAssertEqual(local.fileName, "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.url.path))

        // The hit took a hold; releasing it lets the cache be cleared again.
        var freed = await cache.clear()
        XCTAssertEqual(freed, 0)
        await manager.endUse(cacheKey: local.cacheKey)
        freed = await cache.clear()
        XCTAssertGreaterThan(freed, 0)
    }

    func testASecondDriveReusesTheExtractedISOOfAnArchive() async throws {
        // Memtest86+ is cached as the zip plus its extracted child; a cache hit
        // has to hand back the child, not the archive.
        let cache = ISOCache(locations: locations)
        let zip = try await cache.adopt(fileAt: try scratchFile("mt.iso.zip", size: 1024),
                                        key: "sha256-ee", fileName: "mt86plus_7.20_x86_64.iso.zip",
                                        sha256: "ee",
                                        sourceURL: URL(string: "https://example.test/mt.iso.zip"))
        _ = try await cache.adopt(fileAt: try scratchFile("mt.iso", size: 4096),
                                  key: DownloadArtifact.extractedCacheKey(parentKey: zip.key),
                                  fileName: "mt86plus_7.20_x86_64.iso", sha256: nil,
                                  sourceURL: nil, derivedFromKey: zip.key)

        let manager = DownloadManager(cache: cache, locations: locations, hashing: CryptoKitHashing())
        let request = ISORequest(sourceURL: URL(string: "https://example.test/mt.iso.zip")!,
                                 fileName: "mt86plus_7.20_x86_64.iso.zip", sha256: "ee")
        let local = try await manager.ensureLocalISO(request) { _, _ in }

        XCTAssertEqual(local.fileName, "mt86plus_7.20_x86_64.iso")
        XCTAssertEqual(local.sizeBytes, 4096)
        await manager.endUse(cacheKey: local.cacheKey)
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [DownloadStage] = []
    var stages: [DownloadStage] { lock.withLock { _stages } }
    func record(_ stage: DownloadStage) { lock.withLock { _stages.append(stage) } }
}
