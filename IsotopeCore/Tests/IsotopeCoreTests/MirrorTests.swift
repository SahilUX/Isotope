import XCTest
@testable import IsotopeCore

/// PRD F73: mirror candidates, probe judgement and ranking. All pure, so the
/// whole decision is tested without a network; the app only supplies timings.
final class MirrorTests: XCTestCase {
    private let iso = URL(string: "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso")!
    private let ubuntuRule = MirrorRule(from: "https://releases.ubuntu.com/",
                                        to: ["https://mirrors.kernel.org/ubuntu-releases/",
                                             "https://ftp.example.ac.jp/pub/ubuntu-releases/"])

    // MARK: - Candidates

    func testPrefixRewriteKeepsTheOriginalFirst() {
        let urls = MirrorCandidates.candidates(for: iso, rules: [ubuntuRule])
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso",
            "https://mirrors.kernel.org/ubuntu-releases/26.04/ubuntu-26.04.1-desktop-amd64.iso",
            "https://ftp.example.ac.jp/pub/ubuntu-releases/26.04/ubuntu-26.04.1-desktop-amd64.iso"
        ])
    }

    func testARuleForAnotherOriginAddsNothing() {
        let debian = MirrorRule(from: "https://cdimage.debian.org/debian-cd/",
                                to: ["https://mirrors.kernel.org/debian-cd/"])
        XCTAssertEqual(MirrorCandidates.candidates(for: iso, rules: [debian]), [iso])
        XCTAssertEqual(MirrorCandidates.candidates(for: iso, rules: []), [iso])
    }

    func testOnlyHTTPSMirrorsAreAccepted() {
        let rule = MirrorRule(from: "https://releases.ubuntu.com/",
                              to: ["http://mirror.example/ubuntu/", "ftp://mirror.example/ubuntu/",
                                   "https:///no-host/", "https://good.example/ubuntu/"])
        let urls = MirrorCandidates.candidates(for: iso, rules: [rule])
        XCTAssertEqual(urls.map { $0.host ?? "" }, ["releases.ubuntu.com", "good.example"])
    }

    func testDuplicatesCollapseAndTheOriginalIsNeverRepeated() {
        let rules = [
            MirrorRule(from: "https://releases.ubuntu.com/",
                       to: ["https://releases.ubuntu.com/", "https://a.example/u/", "https://a.example/u/"]),
            MirrorRule(from: "https://releases.ubuntu.com/26.04/", to: ["https://a.example/u/26.04/"])
        ]
        let urls = MirrorCandidates.candidates(for: iso, rules: rules)
        XCTAssertEqual(urls.map(\.absoluteString), [
            iso.absoluteString,
            "https://a.example/u/26.04/ubuntu-26.04.1-desktop-amd64.iso"
        ])
    }

    func testAnHTTPOriginIsStillOfferedFirst() {
        let plain = URL(string: "http://old.example/iso/x.iso")!
        let rule = MirrorRule(from: "http://old.example/iso/", to: ["https://new.example/iso/"])
        XCTAssertEqual(MirrorCandidates.candidates(for: plain, rules: [rule]).map(\.absoluteString),
                       ["http://old.example/iso/x.iso", "https://new.example/iso/x.iso"])
    }

    func testAChannelOverrideReplacesTheEntrysRules() {
        let provider = ProviderConfig.staticURL(url: iso, checksumURL: nil)
        let entry = CatalogEntry(id: "ubuntu-desktop", name: "Ubuntu Desktop", kind: .linux,
                                 channels: [Channel(id: "lts", name: "LTS", provider: provider),
                                            Channel(id: "none", name: "None", provider: provider,
                                                    mirrors: [])],
                                 isBuiltIn: true, mirrors: [ubuntuRule])
        XCTAssertEqual(entry.downloadCandidates(for: iso, channelID: "lts").count, 3)
        XCTAssertEqual(entry.downloadCandidates(for: iso, channelID: "none"), [iso])
        XCTAssertEqual(entry.downloadCandidates(for: iso, channelID: nil).count, 3)
    }

    // MARK: - Content-Range

    func testContentRangeTotalParses() {
        XCTAssertEqual(MirrorRanking.contentRangeTotal("bytes 0-1048575/6234542080"), 6_234_542_080)
        XCTAssertEqual(MirrorRanking.contentRangeTotal("bytes 0-99/100 "), 100)
        XCTAssertNil(MirrorRanking.contentRangeTotal("bytes 0-1048575/*"))
        XCTAssertNil(MirrorRanking.contentRangeTotal("bytes */6234542080x"))
        XCTAssertNil(MirrorRanking.contentRangeTotal(nil))
    }

    // MARK: - Ranking

    private let size: Int64 = 6_000_000_000
    private let mib: Int64 = 1 << 20
    private let primary = URL(string: "https://origin.example/x.iso")!
    private let fast = URL(string: "https://fast.example/x.iso")!
    private let slow = URL(string: "https://slow.example/x.iso")!

    private func answered(_ url: URL, seconds: TimeInterval, total: Int64? = nil,
                          bytes: Int64? = nil, status: Int = 206) -> MirrorProbeResult {
        MirrorProbeResult(url: url, statusCode: status, contentRangeTotal: total ?? size,
                          bytesReceived: bytes ?? mib, elapsed: seconds)
    }

    func testAClearlyFasterMirrorGoesFirst() {
        let ranked = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1.0), answered(fast, seconds: 0.2), answered(slow, seconds: 2.0)
        ], expectedSize: nil)
        XCTAssertEqual(ranked, [fast, primary, slow])
    }

    func testAMirrorMustBeatTheOriginalByAQuarter() {
        // 20% faster is within the noise of one 1 MiB sample: stay put.
        let ranked = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1.0), answered(fast, seconds: 1.0 / 1.2)
        ], expectedSize: nil)
        XCTAssertEqual(ranked, [primary, fast])

        let decisive = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1.0), answered(fast, seconds: 1.0 / 1.3)
        ], expectedSize: nil)
        XCTAssertEqual(decisive, [fast, primary])
    }

    func testIneligibleMirrorsAreDropped() {
        let wrongSize = URL(string: "https://stale.example/x.iso")!
        let ignoresRange = URL(string: "https://whole.example/x.iso")!
        let short = URL(string: "https://short.example/x.iso")!
        let missing = URL(string: "https://missing.example/x.iso")!
        let unknownTotal = URL(string: "https://star.example/x.iso")!
        let ranked = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1.0),
            answered(wrongSize, seconds: 0.1, total: size - 1),
            answered(ignoresRange, seconds: 0.1, status: 200),
            answered(short, seconds: 0.1, bytes: 1000),
            MirrorProbeResult(url: missing, statusCode: 404, elapsed: 0.05),
            MirrorProbeResult(url: unknownTotal, statusCode: 206, contentRangeTotal: nil,
                              bytesReceived: mib, elapsed: 0.1)
        ], expectedSize: nil)
        XCTAssertEqual(ranked, [primary])
    }

    func testTheOriginalIsKeptAsTheLastResortWhenItsProbeFails() {
        let ranked = MirrorRanking.rank(primary: primary, results: [
            .failed(primary, elapsed: 6), answered(slow, seconds: 2), answered(fast, seconds: 0.5)
        ], expectedSize: size)
        XCTAssertEqual(ranked, [fast, slow, primary])
    }

    func testWithNothingToCompareAgainstNoMirrorIsTrusted() {
        // No expected size and no total from the original: a stale file on a
        // mirror would be indistinguishable from the right one.
        let ranked = MirrorRanking.rank(primary: primary, results: [
            .failed(primary), answered(fast, seconds: 0.1)
        ], expectedSize: nil)
        XCTAssertEqual(ranked, [primary])
    }

    func testTheExpectedSizeIsTheReferenceWhenKnown() {
        let ranked = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1, total: size), answered(fast, seconds: 0.1, total: size)
        ], expectedSize: size + 10)
        // Neither matches what the catalog said the file is: nothing to rank,
        // but the original is still there to try.
        XCTAssertEqual(ranked, [primary])
    }

    func testASmallFileOnlyNeedsToArriveWhole() {
        let tiny: Int64 = 4096
        let ranked = MirrorRanking.rank(primary: primary, results: [
            answered(primary, seconds: 1, total: tiny, bytes: tiny),
            answered(fast, seconds: 0.1, total: tiny, bytes: tiny)
        ], expectedSize: nil)
        XCTAssertEqual(ranked, [fast, primary])
    }

    func testNoProbeResultsMeansJustTheOriginal() {
        XCTAssertEqual(MirrorRanking.rank(primary: primary, results: [], expectedSize: size), [primary])
    }

    // MARK: - Probe run

    private let quick = MirrorProbeLimits(perProbeTimeout: 2, graceMultiplier: 2, graceFloor: 0.2)

    func testStragglersAreCutOffAfterTheGracePeriod() async {
        let (primary, fast) = (self.primary, self.fast)
        let started = ContinuousClock.now
        let results = await MirrorProbeRun.collect([primary, fast, slow], limits: quick) { url in
            let delay: Duration = url == fast ? .milliseconds(50) : url == primary ? .milliseconds(120) : .seconds(10)
            try? await Task.sleep(for: delay)
            return MirrorProbeResult(url: url, statusCode: 206, contentRangeTotal: 10,
                                     bytesReceived: 10, elapsed: delay / .seconds(1))
        }
        let waited = started.duration(to: .now)
        XCTAssertEqual(Set(results.map(\.url)), [primary, fast])
        XCTAssertLessThan(waited, .seconds(1.5), "the 10 s straggler must not be waited for")
    }

    func testFastFailuresDoNotStartTheGraceClock() async {
        let dead = URL(string: "https://dead.example/x.iso")!
        let primary = self.primary
        let results = await MirrorProbeRun.collect([dead, primary], limits: quick) { url in
            if url == dead { return .failed(url) }
            try? await Task.sleep(for: .milliseconds(500))
            return MirrorProbeResult(url: url, statusCode: 206, contentRangeTotal: 10,
                                     bytesReceived: 10, elapsed: 0.5)
        }
        // Grace floor is 0.2 s; had the 404 started it, the original would be lost.
        XCTAssertEqual(Set(results.map(\.url)), [dead, primary])
    }

    func testEveryProbeIsBoundedByTheHardTimeout() async {
        let limits = MirrorProbeLimits(perProbeTimeout: 0.3)
        let started = ContinuousClock.now
        let results = await MirrorProbeRun.collect([primary, fast], limits: limits) { url in
            try? await Task.sleep(for: .seconds(10))
            return .failed(url)
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testCancellingTheCallerStopsProbingAtOnce() async {
        let started = ContinuousClock.now
        let run = Task {
            await MirrorProbeRun.collect([primary, fast], limits: .standard) { url in
                try? await Task.sleep(for: .seconds(10))
                return .failed(url)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        run.cancel()
        _ = await run.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testGraceIsTwiceTheFirstAnswerWithAFloor() {
        XCTAssertEqual(MirrorProbeLimits.standard.grace(afterFirstAnswerIn: 0.1), 1.5)
        XCTAssertEqual(MirrorProbeLimits.standard.grace(afterFirstAnswerIn: 2), 4)
    }

    // MARK: - Catalog compatibility

    func testAnEntryWithoutMirrorsDecodesAndEncodesWithoutTheField() throws {
        // A custom-sources.json written before F73.
        let json = #"""
        [{"id":"custom-1","name":"Mine","kind":"custom","isBuiltIn":false,
          "channels":[{"id":"default","name":"Default",
                       "provider":{"mechanism":"staticURL","url":"https://example.org/x.iso"}}]}]
        """#
        let entries = try JSONStore.loadJSON([CatalogEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries[0].mirrors, [])
        XCTAssertNil(entries[0].channels[0].mirrors)

        let written = try JSONStore.makeEncoder().encode(entries)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        XCTAssertEqual(Set(object[0].keys),
                       ["id", "name", "kind", "organization", "channels", "isBuiltIn", "contentProbes"])
        let channel = try XCTUnwrap((object[0]["channels"] as? [[String: Any]])?.first)
        XCTAssertNil(channel["mirrors"])
        XCTAssertEqual(try JSONStore.loadJSON([CatalogEntry].self, from: written), entries)
    }

    func testMirrorsRoundTrip() throws {
        let provider = ProviderConfig.staticURL(url: iso, checksumURL: nil)
        let entry = CatalogEntry(id: "u", name: "U", kind: .linux,
                                 channels: [Channel(id: "a", name: "A", provider: provider,
                                                    mirrors: [MirrorRule(from: "https://x/", to: [])])],
                                 isBuiltIn: true, mirrors: [ubuntuRule])
        let data = try JSONStore.makeEncoder().encode([entry])
        XCTAssertEqual(try JSONStore.loadJSON([CatalogEntry].self, from: data), [entry])
    }

    /// The shipped rules are data; a typo in one should fail here rather than
    /// quietly produce no alternates.
    func testBundledMirrorRulesAreWellFormed() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Isotope/Resources/catalog.json")
        let entries = try JSONStore.loadJSON([CatalogEntry].self, from: Data(contentsOf: catalog))
        let rules = entries.flatMap { $0.mirrors + $0.channels.flatMap { $0.mirrors ?? [] } }
        for rule in rules {
            XCTAssertTrue(rule.from.hasPrefix("https://"), rule.from)
            XCTAssertFalse(rule.to.isEmpty, "\(rule.from) has no mirrors")
            for prefix in rule.to {
                XCTAssertTrue(prefix.hasPrefix("https://"), prefix)
                XCTAssertEqual(prefix.hasSuffix("/"), rule.from.hasSuffix("/"),
                               "\(prefix) and \(rule.from) must agree on the trailing slash")
                XCTAssertNotEqual(prefix, rule.from)
            }
        }
    }
}
