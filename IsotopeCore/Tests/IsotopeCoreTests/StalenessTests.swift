import XCTest
@testable import IsotopeCore

final class StalenessTests: XCTestCase {
    private func token(_ raw: String) -> VersionToken {
        VersionToken.parse(raw)!
    }

    func testVersionComparisonTable() {
        let cases: [(installed: String?, latest: String?, expected: Staleness)] = [
            ("24.04.1", "24.04.3", .stale),
            ("24.04.3", "24.04.3", .upToDate),
            ("24.04", "24.04.0", .upToDate),      // implicit trailing zero
            ("24.10", "24.04.3", .upToDate),      // newer than the source: never "stale"
            ("40", "41", .stale),
            ("41", "41", .upToDate),
            ("2026.07.01", "2026.08.01", .stale), // date-shaped (Arch, ETag sources)
            ("2026.08.01", "2026.08.01", .upToDate),
            ("24.04.3", nil, .unknown),           // no resolved release yet
            (nil, "24.04.3", .unknown),           // installed file, unrecognised name
        ]
        for (installedRaw, latestRaw, expected) in cases {
            let actual = Staleness.evaluate(installedVersion: installedRaw.map(token),
                                            hasInstalledFile: true,
                                            latest: latestRaw.map(token))
            XCTAssertEqual(actual, expected, "installed \(installedRaw ?? "nil") vs latest \(latestRaw ?? "nil")")
        }
    }

    func testNotInstalledOnlyWhenALatestIsKnown() {
        XCTAssertEqual(Staleness.evaluate(installedVersion: nil, hasInstalledFile: false,
                                          latest: token("24.04.3")), .notInstalled)
        XCTAssertEqual(Staleness.evaluate(installedVersion: nil, hasInstalledFile: false,
                                          latest: nil), .unknown)
    }

    func testMixedVersionKindsAreNotComparable() {
        // A source that switched from a semantic version to change-date detection
        // must report "unknown", not a bogus update.
        XCTAssertEqual(Staleness.evaluate(installedVersion: token("24.04.3"), hasInstalledFile: true,
                                          latest: token("2026.08.01")), .unknown)
        XCTAssertEqual(Staleness.evaluate(installedVersion: token("2026.08.01"), hasInstalledFile: true,
                                          latest: token("24.04.3")), .unknown)
    }

    func testNeedsUpdateCoversStaleAndNotInstalled() {
        XCTAssertTrue(Staleness.stale.needsUpdate)
        XCTAssertTrue(Staleness.notInstalled.needsUpdate)
        XCTAssertFalse(Staleness.upToDate.needsUpdate)
        XCTAssertFalse(Staleness.unknown.needsUpdate)
    }

    func testEvaluateFromModelTypes() {
        let release = Release(version: token("24.04.3"), fileName: "ubuntu-24.04.3-desktop-amd64.iso")
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: token("24.04.1"), placedByApp: true)
        XCTAssertEqual(Staleness.evaluate(installed: installed, latest: release), .stale)
        XCTAssertEqual(Staleness.evaluate(installed: nil, latest: release), .notInstalled)
        XCTAssertEqual(Staleness.evaluate(installed: installed, latest: nil), .unknown)
    }

    func testFileNamePatternPerMechanism() {
        let url = URL(string: "https://example.invalid/SHA256SUMS")!
        XCTAssertEqual(ProviderConfig.checksumFile(url: url, filePattern: "a(\\d+)").fileNamePattern, "a(\\d+)")
        XCTAssertEqual(ProviderConfig.pageScrape(url: url, linkPattern: "b(\\d+)").fileNamePattern, "b(\\d+)")
        XCTAssertEqual(ProviderConfig.gitHubReleases(repo: "o/r", assetPattern: "c(\\d+)").fileNamePattern, "c(\\d+)")
        XCTAssertNil(ProviderConfig.staticURL(url: url, checksumURL: nil).fileNamePattern)
        XCTAssertEqual(ProviderConfig.staticURL(url: url, checksumURL: nil,
                                                fileNamePattern: "d.iso").fileNamePattern, "d.iso")
        XCTAssertNil(ProviderConfig.jsonFeed(url: url, spec: JSONFeedSpec(versionKeys: ["v"])).fileNamePattern)
        XCTAssertEqual(ProviderConfig.jsonFeed(url: url, spec: JSONFeedSpec(versionKeys: ["v"]),
                                               fileNamePattern: "e.iso").fileNamePattern, "e.iso")
        XCTAssertNil(ProviderConfig.windowsManual(infoURL: url, downloadPage: url).fileNamePattern)
        // Recognition-only: a Windows config may name its media, and that pattern
        // is what drive scans match on (PRD F41).
        XCTAssertEqual(ProviderConfig.windowsManual(infoURL: url, downloadPage: url,
                                                    fileNamePattern: #"^Win11_.*\.iso$"#).fileNamePattern,
                       #"^Win11_.*\.iso$"#)
    }

    /// Recognising a Windows ISO must not make the entry claim update capability:
    /// the name carries no comparable version, so staleness stays `.unknown`.
    func testWindowsRecognisedFileStaysUnknown() {
        let installed = InstalledISO(fileName: "Win11_25H2_English_x64_v2.iso", version: nil,
                                     placedByApp: false, updatedAt: Date())
        XCTAssertEqual(Staleness.evaluate(installed: installed,
                                          latest: Release(version: VersionToken.parse("26200.7019")!,
                                                          isoURL: nil, fileName: "", sha256: nil,
                                                          sizeBytes: nil)),
                       .unknown)
    }
}
