import XCTest
@testable import IsotopeCore

/// PRD F20: the download cache is size-capped with LRU eviction and hit-tested
/// by (URL, sha256). All policy lives in `CacheIndex`, so all of it is testable
/// without touching a filesystem.
final class CacheIndexTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func artifact(_ key: String, size: Int64, used: TimeInterval,
                          sha: String? = nil, url: String? = nil,
                          parent: String? = nil) -> CachedArtifact {
        CachedArtifact(key: key, fileName: "\(key).iso", sizeBytes: size, sha256: sha,
                       sourceURL: url.flatMap(URL.init(string:)), derivedFromKey: parent,
                       addedAt: epoch, lastUsedAt: epoch.addingTimeInterval(used))
    }

    // MARK: - Basics

    func testTotalBytesAndInsertReplacesSameKey() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("a", size: 100, used: 0))
        index.insert(artifact("b", size: 250, used: 1))
        XCTAssertEqual(index.totalBytes, 350)

        index.insert(artifact("a", size: 500, used: 2))
        XCTAssertEqual(index.artifacts.count, 2)
        XCTAssertEqual(index.totalBytes, 750)
    }

    func testTouchMovesArtifactToTheBackOfTheEvictionQueue() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("old", size: 200, used: 0))
        index.insert(artifact("new", size: 200, used: 10))
        index.touch(key: "old", at: epoch.addingTimeInterval(100))

        // "old" is now the more recently used of the two, so the cap takes "new".
        index.capacityBytes = 200
        XCTAssertEqual(index.evictBeyondCapacity().map(\.key), ["new"])
        XCTAssertNotNil(index.artifact(key: "old"))
    }

    func testTouchIgnoresUnknownKeys() {
        var index = CacheIndex()
        index.touch(key: "nope", at: epoch)
        XCTAssertTrue(index.isEmpty)
    }

    // MARK: - Eviction (LRU + cap)

    func testEvictsLeastRecentlyUsedUntilUnderCap() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("a", size: 400, used: 0))
        index.insert(artifact("b", size: 400, used: 10))
        index.insert(artifact("c", size: 400, used: 20))
        index.capacityBytes = 1000
        let evicted = index.insert(artifact("d", size: 400, used: 30))

        // 1600 > 1000 → drop the two oldest.
        XCTAssertEqual(evicted.map(\.key), ["a", "b"])
        XCTAssertEqual(index.artifacts.map(\.key).sorted(), ["c", "d"])
        XCTAssertLessThanOrEqual(index.totalBytes, index.capacityBytes)
    }

    func testFreshlyInsertedArtifactSurvivesEvenWhenItAloneExceedsTheCap() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("small", size: 100, used: 0))
        index.capacityBytes = 1000
        let evicted = index.insert(artifact("huge", size: 5000, used: 10))

        XCTAssertEqual(evicted.map(\.key), ["small"])
        XCTAssertEqual(index.artifacts.map(\.key), ["huge"])
    }

    func testProtectedArtifactsAreNeverEvicted() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("inuse", size: 400, used: 0))
        index.insert(artifact("idle", size: 400, used: 5))
        index.capacityBytes = 500
        let evicted = index.insert(artifact("new", size: 400, used: 10), protecting: ["inuse"])

        XCTAssertEqual(evicted.map(\.key), ["idle"])
        XCTAssertEqual(index.artifacts.map(\.key).sorted(), ["inuse", "new"])
        // Still over cap, because refusing to evict an in-flight copy is correct.
        XCTAssertGreaterThan(index.totalBytes, index.capacityBytes)
    }

    func testNonPositiveCapacityMeansUnlimited() {
        var index = CacheIndex(capacityBytes: 0)
        for i in 0..<5 { index.insert(artifact("k\(i)", size: 1_000_000, used: Double(i))) }
        XCTAssertEqual(index.artifacts.count, 5)
        XCTAssertTrue(index.evictBeyondCapacity().isEmpty)
    }

    func testEvictingAnArchiveAlsoEvictsItsExtractedISO() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("zip", size: 300, used: 0))
        index.insert(artifact("zip-iso", size: 300, used: 0, parent: "zip"))
        index.capacityBytes = 1000
        let evicted = index.insert(artifact("other", size: 900, used: 10))

        XCTAssertEqual(Set(evicted.map(\.key)), ["zip", "zip-iso"])
        XCTAssertEqual(index.artifacts.map(\.key), ["other"])
    }

    // MARK: - Lookup (PRD F20 cache hit)

    func testLookupMatchesByChecksumAcrossMirrors() {
        var index = CacheIndex()
        index.insert(artifact("a", size: 10, used: 0, sha: "ABCDEF", url: "https://mirror1/x.iso"))

        let hit = index.lookup(sourceURL: URL(string: "https://mirror2/x.iso"), sha256: "abcdef")
        XCTAssertEqual(hit?.key, "a")
    }

    func testLookupFallsBackToSourceURLWhenNoChecksumIsPublished() {
        var index = CacheIndex()
        index.insert(artifact("a", size: 10, used: 0, url: "https://host/x.iso"))

        XCTAssertEqual(index.lookup(sourceURL: URL(string: "https://host/x.iso"), sha256: nil)?.key, "a")
        XCTAssertNil(index.lookup(sourceURL: URL(string: "https://host/y.iso"), sha256: nil))
    }

    func testLookupRejectsSameURLWithADifferentPublishedChecksum() {
        var index = CacheIndex()
        index.insert(artifact("stale", size: 10, used: 0, sha: "aaa", url: "https://host/latest.iso"))

        // The source republished the file: same URL, new hash — that is a miss.
        XCTAssertNil(index.lookup(sourceURL: URL(string: "https://host/latest.iso"), sha256: "bbb"))
    }

    // MARK: - Removal

    func testRemoveDropsTheExtractedChildToo() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("zip", size: 10, used: 0))
        index.insert(artifact("zip-iso", size: 10, used: 0, parent: "zip"))

        XCTAssertEqual(index.remove(key: "zip")?.key, "zip")
        XCTAssertTrue(index.isEmpty)
    }

    func testClearReturnsEverythingButKeepsProtectedEntries() {
        var index = CacheIndex(capacityBytes: 0)
        index.insert(artifact("a", size: 10, used: 0))
        index.insert(artifact("b", size: 10, used: 0))

        let cleared = index.clear(protecting: ["b"])
        XCTAssertEqual(cleared.map(\.key), ["a"])
        XCTAssertEqual(index.artifacts.map(\.key), ["b"])
    }

    func testRoundTripsThroughJSON() throws {
        var index = CacheIndex(capacityBytes: 4096)
        index.insert(artifact("a", size: 10, used: 0, sha: "abc", url: "https://host/a.iso"))
        let data = try JSONStore.makeEncoder().encode(index)
        let decoded = try JSONStore.makeDecoder().decode(CacheIndex.self, from: data)
        XCTAssertEqual(decoded, index)
    }
}
