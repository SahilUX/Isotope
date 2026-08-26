import XCTest
@testable import IsotopeCore

/// PRD F43, end to end over the *shipped* catalog: the user's real filenames on
/// their real Ventoy drive must stop reporting "Unknown".
final class WindowsReleaseTrackingTests: XCTestCase {
    private func windowsEntries() throws -> [CatalogEntry] {
        try ContentProbeTests.bundledCatalog().filter { $0.kind == .windows }
    }

    private func entry(_ id: String) throws -> CatalogEntry {
        guard let entry = try windowsEntries().first(where: { $0.id == id }) else {
            throw XCTSkip("no \(id) entry in the catalog")
        }
        return entry
    }

    // MARK: - Filenames

    /// The two filenames sitting on the user's Ventoy stick right now.
    func testTheUsersOwnFilenamesYieldReleaseTokens() throws {
        let catalog = try ContentProbeTests.bundledCatalog()
        let cases = [("Win11_25H2_English_x64_v2.iso", "windows-11", "25H2"),
                     ("Win10_22H2_English_x64v1.iso", "windows-10", "22H2")]
        for (fileName, entryID, version) in cases {
            guard let detected = ISOContentMatcher.match(fileName: fileName, in: catalog) else {
                return XCTFail("\(fileName) was not recognised at all")
            }
            XCTAssertEqual(detected.entryID, entryID, fileName)
            XCTAssertEqual(detected.version?.raw, version, fileName)
            XCTAssertEqual(detected.version, .windowsRelease(year: Int(version.prefix(2))!,
                                                             half: Int(version.suffix(1))!,
                                                             raw: version))
        }
    }

    func testOtherOfficialMediaNamesStillMatch() throws {
        let catalog = try ContentProbeTests.bundledCatalog()
        let cases: [(String, String, String?)] = [
            ("Win11_23H2_EnglishInternational_x64v2.iso", "windows-11", "23H2"),
            ("Win11_25H2_Arabic_x64.iso", "windows-11", "25H2"),
            ("Win10_21H2_English_x64.iso", "windows-10", "21H2"),
            // Pre-NNHN naming: recognised as the image, but with no version —
            // a matched entry with no version beats a fabricated one.
            ("Win10_1909_English_x64.iso", "windows-10", nil),
            ("Win11_English_x64.iso", "windows-11", nil)
        ]
        for (fileName, entryID, version) in cases {
            guard let detected = ISOContentMatcher.match(fileName: fileName, in: catalog) else {
                return XCTFail("\(fileName) was not recognised")
            }
            XCTAssertEqual(detected.entryID, entryID, fileName)
            XCTAssertEqual(detected.version?.raw, version, fileName)
        }
    }

    // MARK: - Staleness

    /// The bug this feature exists to fix: installed "25H2" against latest
    /// "25H2" is "Up to date", not "Unknown".
    func testAdoptedWindowsAssignmentsCompareInsteadOfReportingUnknown() {
        let installed = VersionToken.parse("25H2")!
        XCTAssertEqual(Staleness.evaluate(installedVersion: installed, hasInstalledFile: true,
                                          latest: VersionToken.parse("25H2")), .upToDate)
        XCTAssertEqual(Staleness.evaluate(installedVersion: VersionToken.parse("22H2"),
                                          hasInstalledFile: true,
                                          latest: VersionToken.parse("25H2")), .stale)
        XCTAssertEqual(Staleness.evaluate(installedVersion: VersionToken.parse("22H2"),
                                          hasInstalledFile: true,
                                          latest: VersionToken.parse("22H2")), .upToDate)
    }

    /// And the guardrail: a release token and a build number stay incomparable,
    /// so a half-migrated cache reports "Unknown" rather than a bogus update.
    func testReleaseTokenAgainstBuildNumberStaysUnknown() {
        XCTAssertEqual(Staleness.evaluate(installedVersion: VersionToken.parse("25H2"),
                                          hasInstalledFile: true,
                                          latest: VersionToken.parse("26200.9168")), .unknown)
        XCTAssertEqual(Staleness.evaluate(installedVersion: VersionToken.parse("19045.7663"),
                                          hasInstalledFile: true,
                                          latest: VersionToken.parse("22H2")), .unknown)
    }

    // MARK: - Catalog wiring

    func testWindowsChannelsTrackReleaseTokensAndKeepTheBuildAsDetail() throws {
        for entry in try windowsEntries() {
            for channel in entry.channels {
                guard case .windowsManual(_, _, let versionPattern, let fileNamePattern,
                                          let buildInfoURL, let buildPattern, _) = channel.provider
                else { return XCTFail("\(entry.id) is not a windowsManual channel any more") }
                let version = try XCTUnwrap(versionPattern, "\(entry.id) needs a version pattern")
                let matcher = try PatternMatcher(version)
                // The pattern reads a feature release out of Microsoft's own
                // download-page wording.
                let sample = "Windows 11 2025 Update l Version 25H2"
                XCTAssertEqual(matcher.capturedVersion(in: sample), "25H2", entry.id)
                XCTAssertNotNil(try XCTUnwrap(fileNamePattern).range(of: #"(\d{2}H\d)"#))
                // The build is display-only, and only fetched when configured.
                XCTAssertNotNil(buildInfoURL, "\(entry.id) should still show its build number")
                XCTAssertTrue(try XCTUnwrap(buildPattern)
                    .contains(WindowsInfoProvider.versionPlaceholder), entry.id)
            }
        }
    }

    /// PRD F32 is untouched: Windows is still never offered as a flash target.
    func testWindowsStaysNonFlashable() throws {
        let catalog = try ContentProbeTests.bundledCatalog()
        let flashable = Set(FlashEligibility.flashableEntries(catalog).map(\.id))
        for entry in try windowsEntries() {
            XCTAssertFalse(flashable.contains(entry.id), "\(entry.id) must not be flashable")
            XCTAssertTrue(entry.channels.allSatisfy { !$0.provider.isFlashable })
        }
    }
}
