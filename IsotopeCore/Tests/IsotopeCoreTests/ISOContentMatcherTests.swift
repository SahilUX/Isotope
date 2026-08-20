import XCTest
@testable import IsotopeCore

/// PRD F41: unclaimed `.iso` files on a Ventoy drive matched against the whole
/// catalog. Patterns are the real ones out of `catalog.json`.
final class ISOContentMatcherTests: XCTestCase {
    // MARK: - Fixtures

    private func channel(_ id: String, pattern: String?) -> Channel {
        guard let pattern else {
            return Channel(id: id, name: id,
                           provider: .staticURL(url: URL(string: "https://example.invalid/x.iso")!,
                                                checksumURL: nil))
        }
        return Channel(id: id, name: id,
                       provider: .checksumFile(url: URL(string: "https://example.invalid/SHA256SUMS")!,
                                               filePattern: pattern))
    }

    private var ubuntu: CatalogEntry {
        CatalogEntry(id: "ubuntu-desktop", name: "Ubuntu Desktop", kind: .linux,
                     organization: "Ubuntu",
                     channels: [channel("lts", pattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#),
                                channel("latest", pattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#)],
                     isBuiltIn: true)
    }

    private var debian: CatalogEntry {
        CatalogEntry(id: "debian", name: "Debian", kind: .linux, organization: "Debian",
                     channels: [channel("netinst", pattern: #"^debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso$"#),
                                channel("dvd", pattern: #"^debian-(\d+\.\d+\.\d+)-amd64-DVD-1\.iso$"#)],
                     isBuiltIn: true)
    }

    /// No filename pattern at all (`staticURL`), so it can never be detected.
    private var nixos: CatalogEntry {
        CatalogEntry(id: "nixos", name: "NixOS", kind: .linux, organization: "NixOS",
                     channels: [channel("minimal", pattern: nil)], isBuiltIn: true)
    }

    /// Versionless: the pattern matches but captures nothing parseable.
    private var rescue: CatalogEntry {
        CatalogEntry(id: "rescue-tool", name: "Rescue Tool", kind: .tool, organization: "Tools",
                     channels: [channel("default", pattern: #"^rescue-(latest)\.iso$"#)],
                     isBuiltIn: true)
    }

    /// Two entries whose patterns both claim `overlap-1.0.iso`.
    private var greedyA: CatalogEntry {
        CatalogEntry(id: "greedy-a", name: "Greedy A", kind: .tool, organization: "Tools",
                     channels: [channel("default", pattern: #"^overlap-(\d+\.\d+)\.iso$"#)],
                     isBuiltIn: true)
    }

    private var greedyB: CatalogEntry {
        CatalogEntry(id: "greedy-b", name: "Greedy B", kind: .tool, organization: "Tools",
                     channels: [channel("default", pattern: #"overlap-(\d+\.\d+)"#)], isBuiltIn: true)
    }

    private var catalog: [CatalogEntry] { [ubuntu, debian, nixos, rescue] }

    // MARK: - Matching

    func testMatchesOneChannelWithItsVersion() {
        let detected = ISOContentMatcher.match(fileName: "debian-12.7.0-amd64-netinst.iso",
                                               in: catalog)
        XCTAssertEqual(detected?.entryID, "debian")
        XCTAssertEqual(detected?.channelID, "netinst")
        XCTAssertEqual(detected?.version, VersionToken.parse("12.7.0"))
        XCTAssertEqual(detected?.id, "debian-12.7.0-amd64-netinst.iso")
    }

    /// Ubuntu's LTS and Latest channels share one pattern: the image is known,
    /// the channel is the user's call.
    func testSeveralChannelsOfOneEntryLeaveTheChannelOpen() {
        let detected = ISOContentMatcher.match(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                               in: catalog)
        XCTAssertEqual(detected?.entryID, "ubuntu-desktop")
        XCTAssertNil(detected?.channelID)
        XCTAssertEqual(detected?.version, VersionToken.parse("24.04.1"))
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                            entry: ubuntu),
                       ["lts", "latest"])
    }

    func testTwoEntriesClaimingOneFileAreNotOffered() {
        XCTAssertNil(ISOContentMatcher.match(fileName: "overlap-1.0.iso", in: [greedyA, greedyB]))
        // Either one alone is unambiguous.
        XCTAssertEqual(ISOContentMatcher.match(fileName: "overlap-1.0.iso", in: [greedyA])?.entryID,
                       "greedy-a")
    }

    func testVersionlessMatchIsStillOffered() {
        let detected = ISOContentMatcher.match(fileName: "rescue-latest.iso", in: catalog)
        XCTAssertEqual(detected?.entryID, "rescue-tool")
        XCTAssertEqual(detected?.channelID, "default")
        XCTAssertNil(detected?.version)
    }

    func testEntriesWithoutFileNamePatternsNeverMatch() {
        XCTAssertNil(ISOContentMatcher.match(fileName: "nixos-minimal-24.05-x86_64-linux.iso",
                                             in: catalog))
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "anything.iso", entry: nixos), [])
    }

    func testUnrecognisedAndNonISOFilesAreIgnored() {
        XCTAssertNil(ISOContentMatcher.match(fileName: "holiday-photos.iso", in: catalog))
        XCTAssertNil(ISOContentMatcher.match(fileName: "debian-12.7.0-amd64-netinst.iso.part",
                                             in: catalog))
        XCTAssertNil(ISOContentMatcher.match(fileName: "._debian-12.7.0-amd64-netinst.iso",
                                             in: catalog))
    }

    // MARK: - Listings

    func testDetectFiltersAndOrdersTheListing() {
        let files = ["ubuntu-24.04.1-desktop-amd64.iso",
                     "debian-12.7.0-amd64-netinst.iso",
                     "notes.txt",
                     "._debian-12.7.0-amd64-netinst.iso",
                     "some-random-image.iso"]
        let detected = ISOContentMatcher.detect(unclaimedFiles: files, in: catalog)
        XCTAssertEqual(detected.map(\.fileName),
                       ["debian-12.7.0-amd64-netinst.iso", "ubuntu-24.04.1-desktop-amd64.iso"])
        XCTAssertEqual(detected.map(\.entryID), ["debian", "ubuntu-desktop"])
    }

    // MARK: - The real catalog

    /// The bundled catalog is the thing users actually run against: these are the
    /// filenames a real Ventoy drive was found to hold and that F41 must offer.
    private func bundledCatalog() throws -> [CatalogEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IsotopeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // IsotopeCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Isotope/Resources/catalog.json")
        return try JSONStore.loadJSON([CatalogEntry].self, from: try Data(contentsOf: url))
    }

    func testUbuntuServerISOIsRecognisedByTheRealCatalog() throws {
        let catalog = try bundledCatalog()
        let detected = ISOContentMatcher.match(fileName: "ubuntu-26.04-live-server-amd64.iso",
                                               in: catalog)
        XCTAssertEqual(detected?.entryID, "ubuntu-server")
        // LTS and Latest share the pattern, so the channel stays the user's call.
        XCTAssertNil(detected?.channelID)
        XCTAssertEqual(detected?.version, VersionToken.parse("26.04"))

        let lts = ISOContentMatcher.match(fileName: "ubuntu-24.04.4-live-server-amd64.iso",
                                          in: catalog)
        XCTAssertEqual(lts?.entryID, "ubuntu-server")
        XCTAssertEqual(lts?.version, VersionToken.parse("24.04.4"))
    }

    /// Server and Desktop must not swallow each other's ISOs — they are separate
    /// entries whose patterns differ only in the middle segment.
    func testUbuntuServerAndDesktopDoNotMatchEachOther() throws {
        let catalog = try bundledCatalog()
        let desktop = try XCTUnwrap(catalog.first { $0.id == "ubuntu-desktop" })
        let server = try XCTUnwrap(catalog.first { $0.id == "ubuntu-server" })

        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "ubuntu-26.04-live-server-amd64.iso",
                                                            entry: desktop), [])
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "ubuntu-26.04-desktop-amd64.iso",
                                                            entry: server), [])
        XCTAssertEqual(ISOContentMatcher.match(fileName: "ubuntu-26.04-desktop-amd64.iso",
                                               in: catalog)?.entryID, "ubuntu-desktop")
    }

    /// PRD F41 + F43: Microsoft's official media names are recognised, and since
    /// v1.5 the `NNHN` feature release in them *is* the version — that is what
    /// the entry tracks, so the two sides finally compare.
    func testWindowsMediaNamesCarryTheirFeatureRelease() throws {
        let catalog = try bundledCatalog()

        let win10 = ISOContentMatcher.match(fileName: "Win10_22H2_English_x64v1.iso", in: catalog)
        XCTAssertEqual(win10?.entryID, "windows-10")
        XCTAssertEqual(win10?.channelID, "default")
        XCTAssertEqual(win10?.version, .windowsRelease(year: 22, half: 2, raw: "22H2"))

        let win11 = ISOContentMatcher.match(fileName: "Win11_25H2_English_x64_v2.iso", in: catalog)
        XCTAssertEqual(win11?.entryID, "windows-11")
        XCTAssertEqual(win11?.channelID, "default")
        XCTAssertEqual(win11?.version, .windowsRelease(year: 25, half: 2, raw: "25H2"))

        // Pre-NNHN media still matches the entry, still with no version.
        XCTAssertNil(ISOContentMatcher.match(fileName: "Win10_1909_English_x64.iso",
                                             in: catalog)?.version,
                     "nil beats a fabricated version")
    }

    func testWindowsLanguageAndRevisionVariants() throws {
        let catalog = try bundledCatalog()
        let expected: [(String, String)] = [
            ("Win11_24H2_EnglishInternational_x64.iso", "windows-11"),
            ("Win11_23H2_Chinese_Simplified_x64v1.iso", "windows-11"),
            ("Win11_24H2_English_Arm64.iso", "windows-11"),
            ("win11_25h2_english_x64_v2.iso", "windows-11"),
            ("Win10_22H2_French_x64.iso", "windows-10"),
            ("Win10_22H2_BrazilianPortuguese_x32.iso", "windows-10"),
            ("Win10_1909_English_x64.iso", "windows-10")
        ]
        for (fileName, entryID) in expected {
            XCTAssertEqual(ISOContentMatcher.match(fileName: fileName, in: catalog)?.entryID,
                           entryID, "expected \(fileName) to match \(entryID)")
        }
    }

    /// Feed- and static-URL-backed entries name no filename in their pattern for
    /// the provider's sake — these patterns exist purely so a drive scan can
    /// recognise the image (PRD F41). Filenames are the live ones
    /// `verify-catalog` resolved.
    func testFeedAndStaticEntriesAreRecognisedByFileName() throws {
        let catalog = try bundledCatalog()

        // Fedora and Tails put the feed's own version in the filename, so it is captured.
        let fedora = ISOContentMatcher.match(fileName: "Fedora-Workstation-Live-44-1.7.x86_64.iso",
                                             in: catalog)
        XCTAssertEqual(fedora?.entryID, "fedora-workstation")
        XCTAssertEqual(fedora?.version, VersionToken.parse("44"))
        // The pre-42 ordering of the same name still matches.
        XCTAssertEqual(ISOContentMatcher.match(fileName: "Fedora-Workstation-Live-x86_64-40-1.14.iso",
                                               in: catalog)?.entryID, "fedora-workstation")

        let tails = ISOContentMatcher.match(fileName: "tails-amd64-7.10.1.iso", in: catalog)
        XCTAssertEqual(tails?.entryID, "tails")
        XCTAssertEqual(tails?.version, VersionToken.parse("7.10.1"))

        // Pop!_OS splits release and build across two segments, so nothing is
        // captured: a nil version is honest, a half version would read as stale.
        let intel = ISOContentMatcher.match(fileName: "pop-os_24.04_amd64_intel_20.iso", in: catalog)
        XCTAssertEqual(intel?.entryID, "pop-os")
        XCTAssertEqual(intel?.channelID, "intel")
        XCTAssertNil(intel?.version)
        let nvidia = ISOContentMatcher.match(fileName: "pop-os_24.04_amd64_nvidia_27.iso", in: catalog)
        XCTAssertEqual(nvidia?.channelID, "nvidia")

        // NixOS: both the channel redirect name and the versioned release name.
        for (fileName, channelID) in [("latest-nixos-minimal-x86_64-linux.iso", "minimal"),
                                      ("nixos-minimal-26.05.7813.0dd31db7e6db-x86_64-linux.iso", "minimal"),
                                      ("latest-nixos-graphical-x86_64-linux.iso", "graphical"),
                                      ("nixos-graphical-26.05.7813.0dd31db7e6db-x86_64-linux.iso", "graphical")] {
            let detected = ISOContentMatcher.match(fileName: fileName, in: catalog)
            XCTAssertEqual(detected?.entryID, "nixos", "\(fileName)")
            XCTAssertEqual(detected?.channelID, channelID, "\(fileName)")
            // staticURL versions are change dates; the filename holds none.
            XCTAssertNil(detected?.version, "\(fileName)")
        }
    }

    /// Sibling channels must not cross-match, or the offer would name the wrong
    /// image (Pop!_OS's NVIDIA build is a different ISO, not a different version).
    func testSiblingChannelsDoNotCrossMatch() throws {
        let catalog = try bundledCatalog()
        let pop = try XCTUnwrap(catalog.first { $0.id == "pop-os" })
        let nixos = try XCTUnwrap(catalog.first { $0.id == "nixos" })

        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "pop-os_24.04_amd64_intel_20.iso",
                                                            entry: pop), ["intel"])
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "pop-os_24.04_amd64_nvidia_27.iso",
                                                            entry: pop), ["nvidia"])
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "latest-nixos-minimal-x86_64-linux.iso",
                                                            entry: nixos), ["minimal"])
        XCTAssertEqual(ISOContentMatcher.matchingChannelIDs(fileName: "nixos-graphical-26.05.7813.0dd31db7e6db-x86_64-linux.iso",
                                                            entry: nixos), ["graphical"])
        // Neither entry claims a plausible-looking neighbour.
        for fileName in ["pop-os_24.04_amd64_intel.iso", "nixos-minimal-x86.iso",
                         "tails-amd64-7.10.1.img.iso", "Fedora-Server-Live-44-1.7.x86_64.iso"] {
            XCTAssertNil(ISOContentMatcher.match(fileName: fileName, in: catalog), fileName)
        }
    }

    /// Memtest86+ is published as `…_x86_64.iso.zip` but placed on the drive
    /// unpacked, so its pattern has to match the unpacked name too.
    func testMemtestUnpackedISOIsRecognised() throws {
        let catalog = try bundledCatalog()
        let detected = ISOContentMatcher.match(fileName: "mt86plus_8.10_x86_64.iso", in: catalog)
        XCTAssertEqual(detected?.entryID, "memtest86plus")
        XCTAssertEqual(detected?.version, VersionToken.parse("8.10"))
        // The published archive name still matches, so the provider keeps working.
        let entry = try XCTUnwrap(catalog.first { $0.id == "memtest86plus" })
        let pattern = try XCTUnwrap(entry.channels.first?.provider.fileNamePattern)
        XCTAssertTrue(try PatternMatcher(pattern).matchesAnywhere("mt86plus_8.10_x86_64.iso.zip"))
    }

    func testWindowsPatternsDoNotClaimUnrelatedFiles() throws {
        let catalog = try bundledCatalog()
        for fileName in ["my-Win11-backup.iso", "Win11.iso", "Windows11_setup.iso",
                         "Win12_25H2_English_x64.iso"] {
            XCTAssertNil(ISOContentMatcher.match(fileName: fileName, in: catalog),
                         "\(fileName) must not be offered")
        }
    }

    /// The exclusive-claim rule: a second, older Ubuntu ISO next to one an
    /// assignment already holds is still unclaimed, so it is still offered.
    func testASecondCopyOfAnAssignedEntryIsOfferedWhenTheFileItselfIsUnclaimed() {
        let listing = ["ubuntu-24.04.1-desktop-amd64.iso", "ubuntu-24.04.3-desktop-amd64.iso"]
        let tracker = ReconcileInput(assignmentID: UUID(),
                                     fileNamePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#,
                                     releaseFileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                     releaseVersion: VersionToken.parse("24.04.3"))
        let result = DriveReconciler.reconcile(fileNames: listing, assignments: [tracker])
        XCTAssertEqual(result.unknownFiles, ["ubuntu-24.04.1-desktop-amd64.iso"])

        let detected = ISOContentMatcher.detect(unclaimedFiles: result.unknownFiles, in: catalog)
        XCTAssertEqual(detected.map(\.fileName), ["ubuntu-24.04.1-desktop-amd64.iso"])
        XCTAssertEqual(detected.first?.version, VersionToken.parse("24.04.1"))
    }
}
