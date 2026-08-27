import XCTest
@testable import IsotopeCore

/// PRD F48: the media revision — which *issue* of a Windows release a file is,
/// and what the comparison does when Microsoft ships a new one. Fixture-driven,
/// from real response bodies observed on Microsoft's download connector.
final class WindowsMediaTests: XCTestCase {
    // MARK: - Reading the display name

    func testReadsReleaseAndRevisionFromMicrosoftsDisplayNames() throws {
        // The separator differs between the two products, which is exactly the
        // kind of thing a stricter pattern would silently miss.
        let cases: [(String, String, Int)] = [
            ("Windows 11 25H2__V2", "25H2", 2),
            ("Windows 10 22H2_v1", "22H2", 1),
            ("Windows 11 24H2", "24H2", 1),
            ("Windows 11 26H1__V11", "26H1", 11),
        ]
        for (name, release, revision) in cases {
            let identity = try XCTUnwrap(WindowsMediaName.identity(productDisplayName: name), name)
            XCTAssertEqual(identity.release.raw, release, name)
            XCTAssertEqual(identity.revision, revision, name)
        }
    }

    func testADisplayNameWithNoFeatureReleaseSaysNothing() {
        XCTAssertNil(WindowsMediaName.identity(productDisplayName: "Windows 11"))
        XCTAssertNil(WindowsMediaName.identity(productDisplayName: "Ubuntu 24.04"))
    }

    // MARK: - Reading the filename

    func testReadsTheRevisionOffMicrosoftsFilenames() {
        XCTAssertEqual(WindowsMediaName.revision(fromFileName: "Win11_25H2_English_x64v2.iso"), 2)
        XCTAssertEqual(WindowsMediaName.revision(fromFileName: "Win11_25H2_English_x64_v2.iso"), 2)
        // No suffix is issue 1, not "unknown" — that is what makes an original
        // ISO comparable against a V2 on the download page.
        XCTAssertEqual(WindowsMediaName.revision(fromFileName: "Win11_25H2_English_x64.iso"), 1)
        XCTAssertEqual(WindowsMediaName.revision(fromFileName: "Win10_22H2_English_x64.iso"), 1)
        XCTAssertEqual(WindowsMediaName.revision(fromFileName: "Win11_25H2_EnglishInternational_arm64.iso"), 1)
    }

    func testAFileThatIsNotMicrosoftsNamingClaimsNoRevision() {
        // A renamed or third-party image says nothing about its issue, and
        // assuming 1 would invent an update the day Microsoft shipped a V2.
        XCTAssertNil(WindowsMediaName.revision(fromFileName: "windows11.iso"))
        XCTAssertNil(WindowsMediaName.revision(fromFileName: "Win11_25H2_English_x64.img"))
        XCTAssertNil(WindowsMediaName.revision(fromFileName: "ubuntu-24.04.4-desktop-amd64.iso"))
    }

    func testTheOriginalIssueIsWrittenWithoutASuffix() {
        XCTAssertNil(WindowsMediaName.displaySuffix(revision: 1))
        XCTAssertNil(WindowsMediaName.displaySuffix(revision: nil))
        XCTAssertEqual(WindowsMediaName.displaySuffix(revision: 3), "v3")
    }

    // MARK: - The SKU response

    private let catalog = WindowsMediaCatalog(
        url: URL(string: "https://www.microsoft.com/software-download-connector/api")!,
        productEditionID: "3321")

    /// Trimmed from a real response.
    private func skuResponse(displayName: String = "Windows 11 25H2__V2") -> Data {
        Data("""
        {"ValidationContainer":{"Errors":[]},"Skus":[
          {"Id":"20035","Language":"Arabic","LocalizedProductDisplayName":"Windows 11  Arabic",
           "LocalizedLanguage":"Arabic","ProductDisplayName":"\(displayName)"},
          {"Id":"20046","Language":"English","LocalizedProductDisplayName":"Windows 11  English",
           "LocalizedLanguage":"English","ProductDisplayName":"\(displayName)"}]}
        """.utf8)
    }

    func testFindsTheWantedLanguageInTheSKUResponse() throws {
        let identity = try XCTUnwrap(catalog.identity(inSKUResponse: skuResponse()))
        XCTAssertEqual(identity.release.raw, "25H2")
        XCTAssertEqual(identity.revision, 2)
    }

    func testARejectionPayloadYieldsNothing() {
        let rejected = Data("""
        {"Errors":[{"Key":"ErrorSettings.SentinelReject","Value":"Sentinel marked this request as rejected.","Type":8}]}
        """.utf8)
        XCTAssertNil(catalog.identity(inSKUResponse: rejected))
        XCTAssertNil(catalog.identity(inSKUResponse: Data("<html>blocked</html>".utf8)))
        XCTAssertNil(catalog.identity(inSKUResponse: Data()))
    }

    func testTheRequestCarriesWhatTheDownloadPageSends() throws {
        let url = try XCTUnwrap(catalog.requestURL(sessionID: "abc-123"))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(url.path.hasSuffix("/getskuinformationbyproductedition"))
        XCTAssertEqual(values["ProductEditionId"], "3321")
        XCTAssertEqual(values["sessionId"], "abc-123")
        XCTAssertEqual(values["profile"], WindowsMediaCatalog.defaultProfile)
        XCTAssertEqual(values["sdVersion"], "2")
    }

    // MARK: - What the comparison does with it

    private func assignment(fileName: String, release: String = "25H2",
                            build: String? = nil) -> Assignment {
        Assignment(entryID: "windows-11", channelID: "default",
                   installed: InstalledISO(fileName: fileName,
                                           version: VersionToken.parse(release),
                                           placedByApp: true, build: build))
    }

    private func release(_ token: String = "25H2", revision: Int?, build: String? = nil) -> Release {
        Release(version: VersionToken.parse(token)!, fileName: "", build: build,
                mediaRevision: revision)
    }

    func testANewMediaRevisionIsARealUpdate() {
        // Unlike a servicing build, a reissue can actually be downloaded today.
        let staleness = Staleness.evaluate(assignment: assignment(fileName: "Win11_25H2_English_x64.iso"),
                                           latest: release(revision: 2))
        XCTAssertEqual(staleness, .stale)
        XCTAssertTrue(staleness.needsUpdate)
    }

    func testTheSameRevisionIsUpToDate() {
        XCTAssertEqual(Staleness.evaluate(assignment: assignment(fileName: "Win11_25H2_English_x64v2.iso"),
                                          latest: release(revision: 2)), .upToDate)
    }

    func testMediaNewerThanTheServedRevisionIsNotStale() {
        XCTAssertEqual(Staleness.evaluate(assignment: assignment(fileName: "Win11_25H2_English_x64v3.iso"),
                                          latest: release(revision: 2)), .upToDate)
    }

    func testAFileThatClaimsNoRevisionIsNotDraggedIntoTheComparison() {
        XCTAssertEqual(Staleness.evaluate(assignment: assignment(fileName: "my-windows-copy.iso"),
                                          latest: release(revision: 2)), .upToDate)
    }

    func testAnUnknownServedRevisionDrawsNoConclusion() {
        XCTAssertEqual(Staleness.evaluate(assignment: assignment(fileName: "Win11_25H2_English_x64.iso"),
                                          latest: release(revision: nil)), .upToDate)
    }

    func testTheRevisionOutranksTheServicingBuild() {
        // Both signals disagree with the drive: the revision wins, because it is
        // the one the user can act on.
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "Win11_25H2_English_x64.iso", build: "26200.6584"),
            latest: release(revision: 2, build: "26200.9168"))
        XCTAssertEqual(staleness, .stale)
    }

    func testHoldingTheCurrentMediaIsSimplyUpToDate() {
        // PRD F70. The drive has the media Microsoft is serving — v2 against v2
        // — and the build inside it trails the serviced build, as it always
        // will: servicing ships through Windows Update, not in the ISO. Calling
        // that "Newer build shipped" made every Windows row say so forever,
        // next to a button that re-downloads the identical file.
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "Win11_25H2_English_x64v2.iso", build: "26200.6584"),
            latest: release(revision: 2, build: "26200.9168"))
        XCTAssertEqual(staleness, .upToDate)
        XCTAssertFalse(staleness.needsUpdate)
    }

    func testTheBuildStillSpeaksWhenTheRevisionCannot() {
        // Media that is not named the way Microsoft names it has no revision to
        // compare, so a newer build is the only hint that newer media exists.
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "my-windows-copy.iso", build: "26200.6584"),
            latest: release(revision: 2, build: "26200.9168"))
        XCTAssertEqual(staleness, .buildBehind)
    }

    func testAnUnknownServedRevisionLeavesTheBuildAsTheOnlySignal() {
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "Win11_25H2_English_x64v2.iso", build: "26200.6584"),
            latest: release(revision: nil, build: "26200.9168"))
        XCTAssertEqual(staleness, .buildBehind)
    }

    func testMediaAheadOfTheServedRevisionIsUpToDate() {
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "Win11_25H2_English_x64v3.iso", build: "26200.6584"),
            latest: release(revision: 2, build: "26200.9168"))
        XCTAssertEqual(staleness, .upToDate)
    }

    func testAnOlderReleaseIsStaleWhateverTheRevisions() {
        let staleness = Staleness.evaluate(
            assignment: assignment(fileName: "Win11_24H2_English_x64v3.iso", release: "24H2"),
            latest: release("25H2", revision: 1))
        XCTAssertEqual(staleness, .stale)
    }

    // MARK: - Display

    func testBothSidesOfTheRowNameTheirIssue() {
        XCTAssertEqual(release(revision: 2, build: "26200.9168").displayVersion,
                       "25H2 v2 (build 26200.9168)")
        // The original issue is written the way Microsoft writes it: no suffix.
        XCTAssertEqual(release(revision: 1, build: nil).displayVersion, "25H2")

        let installed = InstalledISO(fileName: "Win11_25H2_English_x64v2.iso",
                                     version: VersionToken.parse("25H2"), placedByApp: true,
                                     build: "26200.6584")
        XCTAssertEqual(installed.displayVersion, "25H2 v2 (build 26200.6584)")
    }
}
