import XCTest
@testable import IsotopeCore

/// PRD F43 addendum: reading the build a Windows image records inside itself,
/// and what the comparison does with it. Fixture-driven — a synthetic WIM is
/// a 208-byte header and a UTF-16 blob, so none of this needs a 6 GB ISO.
final class WindowsImageTests: XCTestCase {
    // MARK: - Fixtures

    /// A WIM/ESD header pointing at an XML resource laid out immediately after it.
    private func makeWIM(xml: String, compressed: Bool = false, magic: String = "MSWIM\0\0\0") -> Data {
        var xmlData = Data([0xFF, 0xFE])   // UTF-16LE BOM, exactly as Microsoft writes it
        xmlData.append(xml.data(using: .utf16LittleEndian)!)

        var header = Data(repeating: 0, count: WindowsImageReader.headerLength)
        header.replaceSubrange(0..<8, with: Array(magic.utf8).prefix(8))

        func write(_ value: UInt64, at offset: Int) {
            for index in 0..<8 {
                header[offset + index] = UInt8truncating(value >> (8 * UInt64(index)))
            }
        }
        let flags: UInt64 = compressed ? 0x04 : 0
        write(UInt64(xmlData.count) | (flags << 56), at: 0x48)   // packed size + flags
        write(UInt64(WindowsImageReader.headerLength), at: 0x50) // offset
        write(UInt64(xmlData.count), at: 0x58)                   // original size
        return header + xmlData
    }

    private func UInt8truncating(_ value: UInt64) -> UInt8 { UInt8(value & 0xFF) }

    private func imageXML(editions: [(String, Int, Int)]) -> String {
        let images = editions.enumerated().map { index, edition in
            """
            <IMAGE INDEX="\(index + 1)"><WINDOWS><ARCH>9</ARCH>\
            <EDITIONID>\(edition.0)</EDITIONID>\
            <VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR>\
            <BUILD>\(edition.1)</BUILD><SPBUILD>\(edition.2)</SPBUILD><SPLEVEL>0</SPLEVEL>\
            </VERSION></WINDOWS></IMAGE>
            """
        }.joined()
        return "<WIM><TOTALBYTES>5726443520</TOTALBYTES>\(images)</WIM>"
    }

    private func identity(of wim: Data) -> WindowsImageIdentity? {
        guard let resource = WindowsImageReader.xmlResource(header: wim.prefix(WindowsImageReader.headerLength)) else {
            return nil
        }
        let start = Int(resource.offset)
        let xml = wim.subdata(in: start..<(start + Int(resource.size)))
        guard let decoded = WindowsImageReader.decodeXML(xml) else { return nil }
        return WindowsImageReader.identity(xml: decoded)
    }

    // MARK: - Reading the image

    func testReadsBuildAndEditionsFromInstallImage() throws {
        let wim = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584),
                                                   ("Professional", 26200, 6584)]))
        let identity = try XCTUnwrap(identity(of: wim))
        XCTAssertEqual(identity.build, "26200.6584")
        XCTAssertEqual(identity.editions, ["Core", "Professional"])
        // The build is a version like any other, so 26200.9168 > 26200.6584.
        XCTAssertEqual(identity.buildToken, VersionToken.parse("26200.6584"))
        XCTAssertTrue(try XCTUnwrap(identity.buildToken) < XCTUnwrap(VersionToken.parse("26200.9168")))
    }

    func testHighestBuildWinsAcrossImages() throws {
        // A refreshed multi-edition ISO can carry images captured at different
        // times; reporting the lowest would understate what is on the drive.
        let wim = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584),
                                                   ("Professional", 26200, 9168)]))
        XCTAssertEqual(identity(of: wim)?.build, "26200.9168")
    }

    func testNonWIMFileIsNotRead() {
        let notAWIM = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584)]), magic: "ISO9660\0")
        XCTAssertNil(WindowsImageReader.xmlResource(header: notAWIM.prefix(WindowsImageReader.headerLength)))
    }

    func testCompressedXMLResourceIsRefusedRatherThanGuessed() {
        let wim = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584)]), compressed: true)
        XCTAssertNil(WindowsImageReader.xmlResource(header: wim.prefix(WindowsImageReader.headerLength)))
    }

    func testShortHeaderIsRefused() {
        let wim = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584)]))
        XCTAssertNil(WindowsImageReader.xmlResource(header: wim.prefix(64)))
    }

    func testOversizedXMLResourceIsRefused() {
        var wim = makeWIM(xml: imageXML(editions: [("Core", 26200, 6584)]))
        // A header claiming a gigabyte of XML is corrupt (or hostile); the
        // reader must not turn that into a gigabyte-sized read.
        let huge = UInt64(1 << 30)
        for index in 0..<8 { wim[0x48 + index] = UInt8((huge >> (8 * UInt64(index))) & 0xFF) }
        XCTAssertNil(WindowsImageReader.xmlResource(header: wim.prefix(WindowsImageReader.headerLength)))
    }

    func testXMLWithoutAVersionBlockSaysNothing() {
        let xml = "<WIM><TOTALBYTES>1</TOTALBYTES><IMAGE INDEX=\"1\"><NAME>Windows 11</NAME></IMAGE></WIM>"
        XCTAssertNil(WindowsImageReader.identity(xml: xml))
    }

    func testDecodeStripsTheByteOrderMark() throws {
        var data = Data([0xFF, 0xFE])
        data.append("<WIM/>".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(WindowsImageReader.decodeXML(data), "<WIM/>")
    }

    // MARK: - What the comparison does with it (PRD F43 addendum)

    private func windowsAssignment(installedBuild: String?, release: String = "25H2",
                                   policy: UpdatePolicy = .trackLatest) -> Assignment {
        Assignment(entryID: "windows-11", channelID: "default",
                   installed: InstalledISO(fileName: "Win11_\(release)_English_x64.iso",
                                           version: VersionToken.parse(release),
                                           placedByApp: false, build: installedBuild),
                   updatePolicy: policy)
    }

    private func windowsRelease(_ release: String = "25H2", build: String?) -> Release {
        Release(version: VersionToken.parse(release)!, fileName: "", build: build)
    }

    func testOlderBuildOfTheCurrentReleaseIsSurfacedButNotAnUpdate() {
        let staleness = Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26200.6584"),
                                           latest: windowsRelease(build: "26200.9168"))
        XCTAssertEqual(staleness, .buildBehind)
        // The whole point: Microsoft may not have reissued the ISO, so this
        // must never be counted as a downloadable update.
        XCTAssertFalse(staleness.needsUpdate)
        XCTAssertTrue(staleness.isCurrent)
    }

    func testMatchingBuildsAreSimplyUpToDate() {
        XCTAssertEqual(Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26200.9168"),
                                          latest: windowsRelease(build: "26200.9168")), .upToDate)
    }

    func testMediaNewerThanThePublishedBuildIsUpToDate() {
        XCTAssertEqual(Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26200.9999"),
                                          latest: windowsRelease(build: "26200.9168")), .upToDate)
    }

    func testAnUnknownBuildOnEitherSideDrawsNoConclusion() {
        XCTAssertEqual(Staleness.evaluate(assignment: windowsAssignment(installedBuild: nil),
                                          latest: windowsRelease(build: "26200.9168")), .upToDate)
        XCTAssertEqual(Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26200.6584"),
                                          latest: windowsRelease(build: nil)), .upToDate)
    }

    func testAnOlderFeatureReleaseIsStaleWhateverTheBuildSays() {
        // 24H2 media with a *higher* build number than 25H2's is still the older
        // release: the release comparison is the one that decides.
        let staleness = Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26100.9999",
                                                                         release: "24H2"),
                                           latest: windowsRelease("25H2", build: "26200.6584"))
        XCTAssertEqual(staleness, .stale)
    }

    func testAPinnedWindowsAssignmentIsNeverBuildBehind() {
        XCTAssertEqual(Staleness.evaluate(assignment: windowsAssignment(installedBuild: "26200.6584",
                                                                        policy: .keepAsIs),
                                          latest: windowsRelease(build: "26200.9168")), .pinned)
    }

    // MARK: - Display

    func testInstalledRowShowsTheBuildItActuallyHolds() {
        let installed = InstalledISO(fileName: "Win11_25H2_English_x64.iso",
                                     version: VersionToken.parse("25H2"), placedByApp: false,
                                     build: "26200.6584")
        XCTAssertEqual(installed.displayVersion, "25H2 (build 26200.6584)")
        XCTAssertEqual(windowsRelease(build: "26200.9168").displayVersion, "25H2 (build 26200.9168)")
    }

    func testRowsWithoutABuildAreUnchanged() {
        let installed = InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                     version: VersionToken.parse("24.04.4"), placedByApp: true)
        XCTAssertEqual(installed.displayVersion, "24.04.4")
        let unrecognised = InstalledISO(fileName: "mystery.iso", placedByApp: false)
        XCTAssertEqual(unrecognised.displayVersion, "mystery.iso")
    }

    func testTheBuildSurvivesAReloadOfDrivesJSON() throws {
        let drive = ManagedDrive(volumeUUID: "UUID-A", displayName: "VENTOY", bookmark: Data(),
                                 assignments: [windowsAssignment(installedBuild: "26200.6584")])
        let data = try JSONEncoder().encode([drive])
        let decoded = try JSONDecoder().decode([ManagedDrive].self, from: data)
        XCTAssertEqual(decoded.first?.assignments.first?.installed?.build, "26200.6584")
    }

    func testDrivesJSONWrittenBeforeBuildsExistedStillLoads() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","volumeUUID":"UUID-A","displayName":"VENTOY",
          "bookmark":"","isoFolder":"","keepOldVersions":false,"kind":"ventoy",
          "assignments":[{"id":"\(UUID().uuidString)","entryID":"windows-11","channelID":"default",
            "installed":{"fileName":"Win11_25H2_English_x64.iso","placedByApp":false,
                         "updatedAt":0}}]}]
        """
        let decoded = try JSONDecoder().decode([ManagedDrive].self, from: Data(json.utf8))
        XCTAssertNil(decoded.first?.assignments.first?.installed?.build)
    }
}
