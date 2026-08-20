import XCTest
@testable import IsotopeCore

/// PRD F44: reading a version out of a flashed image's own marker files.
/// Everything here is fed from a dictionary of file contents — no device, no
/// filesystem — which is exactly the boundary the core half of the feature has.
final class ContentProbeTests: XCTestCase {
    // MARK: - Real marker files, captured live from the published ISOs

    /// `.disk/info` of `proxmox-ve_9.2-1.iso`, read out of the published ISO.
    private let proxmoxInfo = """
    RELEASE='9.2'
    ISORELEASE='1'
    ISONAME='proxmox-ve'
    PRODUCT='pve'
    PRODUCTLONG='Proxmox VE'

    """

    /// `.disk/info` of `debian-13.6.0-amd64-netinst.iso`.
    private let debianInfo =
        #"Debian GNU/Linux 13.6.0 "Trixie" - Official amd64 NETINST with firmware 20260711-09:42"#

    /// `.disk/info` of `ubuntu-24.04.4-desktop-amd64.iso`.
    private let ubuntuInfo = #"Ubuntu 24.04.4 LTS "Noble Numbat" - Release amd64 (20260210)"#

    private let proxmoxProbe = ContentProbe(
        path: ".disk/info",
        pattern: #"^RELEASE='(\d+\.\d+)'[\r\n]+ISORELEASE='(\d+)'"#,
        versionTemplate: "$1-$2")

    private let debianProbe = ContentProbe(path: ".disk/info",
                                           pattern: #"^Debian GNU/Linux (\d+\.\d+\.\d+)\b"#)

    private func reader(_ files: [String: String]) -> (String) -> String? {
        { files[$0] }
    }

    // MARK: - The user's actual case

    /// The whole point of F44: Proxmox's volume label is "PVE" and carries no
    /// version, but its `.disk/info` does — and it must come out in exactly the
    /// format the catalog resolves ("9.2-1"), so the two compare.
    func testProxmoxReleaseAndISOReleaseRejoin() {
        let version = ContentProbeRunner.version(probes: [proxmoxProbe],
                                                 read: reader([".disk/info": proxmoxInfo]))
        XCTAssertEqual(version?.raw, "9.2-1")
        XCTAssertEqual(version, VersionToken.parse("9.2-1"))
        XCTAssertEqual(Staleness.evaluate(installedVersion: version, hasInstalledFile: true,
                                          latest: VersionToken.parse("9.2-1")), .upToDate)
        XCTAssertEqual(Staleness.evaluate(installedVersion: version, hasInstalledFile: true,
                                          latest: VersionToken.parse("9.3-1")), .stale)
    }

    func testDebianAndUbuntuMarkerFiles() {
        XCTAssertEqual(ContentProbeRunner.version(probes: [debianProbe],
                                                  read: reader([".disk/info": debianInfo]))?.raw,
                       "13.6.0")
        let ubuntuProbe = ContentProbe(path: ".disk/info",
                                       pattern: #"^Ubuntu (\d+\.\d+(?:\.\d+)?)\b"#)
        XCTAssertEqual(ContentProbeRunner.version(probes: [ubuntuProbe],
                                                  read: reader([".disk/info": ubuntuInfo]))?.raw,
                       "24.04.4")
    }

    /// "Ubuntu " with a space cannot match an Ubuntu-Server marker file, which
    /// is what keeps the two entries' probes from claiming each other's sticks.
    func testUbuntuProbeDoesNotClaimUbuntuServer() {
        let ubuntuProbe = ContentProbe(path: ".disk/info",
                                       pattern: #"^Ubuntu (\d+\.\d+(?:\.\d+)?)\b"#)
        let serverInfo = #"Ubuntu-Server 24.04.4 LTS "Noble Numbat" - Release amd64 (20260210)"#
        XCTAssertNil(ContentProbeRunner.version(probes: [ubuntuProbe],
                                                read: reader([".disk/info": serverInfo])))
    }

    // MARK: - Table: hit, fallback, miss, malformed

    func testFirstProbeWins() {
        let probes = [ContentProbe(path: ".disk/info", pattern: #"^Thing (\d+\.\d+)"#),
                      ContentProbe(path: "media.repo", pattern: #"version=(\d+)"#)]
        let version = ContentProbeRunner.version(probes: probes, read: reader([
            ".disk/info": "Thing 3.1 - some image",
            "media.repo": "version=9"
        ]))
        XCTAssertEqual(version?.raw, "3.1")
    }

    func testFallsBackToTheSecondProbeWhenTheFirstFileIsMissing() {
        let probes = [ContentProbe(path: ".disk/info", pattern: #"^Thing (\d+\.\d+)"#),
                      ContentProbe(path: "media.repo", pattern: #"version=(\d+)"#)]
        XCTAssertEqual(ContentProbeRunner.version(probes: probes,
                                                  read: reader(["media.repo": "version=9"]))?.raw,
                       "9")
    }

    /// A file that exists but does not match is the same as one that is absent:
    /// move on, never guess.
    func testFallsBackWhenTheFirstFileDoesNotMatch() {
        let probes = [ContentProbe(path: ".disk/info", pattern: #"^Thing (\d+\.\d+)"#),
                      ContentProbe(path: "media.repo", pattern: #"version=(\d+)"#)]
        XCTAssertEqual(ContentProbeRunner.version(probes: probes, read: reader([
            ".disk/info": "Something Else entirely",
            "media.repo": "version=9"
        ]))?.raw, "9")
    }

    func testNoProbesAndNoMatchesYieldNothing() {
        XCTAssertNil(ContentProbeRunner.version(probes: [], read: reader([".disk/info": "Thing 3.1"])))
        XCTAssertNil(ContentProbeRunner.version(probes: [debianProbe], read: reader([:])))
        XCTAssertNil(ContentProbeRunner.version(probes: [debianProbe],
                                                read: reader([".disk/info": ""])))
    }

    func testMalformedContentYieldsNothingRatherThanAWrongVersion() {
        let cases = [
            "Debian GNU/Linux trixie - Official amd64",          // no digits where one is needed
            "\u{0}\u{1}\u{2}binary rubbish",                     // not text at all
            "Debian GNU/Linux 13.6.0"                            // truncated: still fine, see below
        ]
        XCTAssertNil(ContentProbeRunner.version(probes: [debianProbe], read: reader([".disk/info": cases[0]])))
        XCTAssertNil(ContentProbeRunner.version(probes: [debianProbe], read: reader([".disk/info": cases[1]])))
        XCTAssertEqual(ContentProbeRunner.version(probes: [debianProbe],
                                                  read: reader([".disk/info": cases[2]]))?.raw, "13.6.0")
    }

    /// A half-populated template must produce nothing at all: "9.2-" is not a
    /// version, and "9.2" would be a *different* release from "9.2-1".
    func testTemplateReferringToAMissingGroupYieldsNothing() {
        let truncated = "RELEASE='9.2'\nISONAME='proxmox-ve'\n"
        XCTAssertNil(ContentProbeRunner.version(probes: [proxmoxProbe],
                                                read: reader([".disk/info": truncated])))
        let badTemplate = ContentProbe(path: ".disk/info", pattern: #"(\d+\.\d+)"#,
                                       versionTemplate: "$1-$7")
        XCTAssertNil(ContentProbeRunner.version(probes: [badTemplate],
                                                read: reader([".disk/info": "9.2"])))
    }

    func testBrokenPatternDegradesToNoMatch() {
        let broken = ContentProbe(path: ".disk/info", pattern: "([unclosed")
        XCTAssertNil(ContentProbeRunner.version(probes: [broken],
                                                read: reader([".disk/info": "anything"])))
    }

    // MARK: - Path safety

    func testPathsAreNormalisedAndTraversalIsRefused() {
        XCTAssertEqual(ContentProbe(path: "/.disk/info", pattern: "x").safeRelativePath, ".disk/info")
        XCTAssertEqual(ContentProbe(path: "./.disk//info", pattern: "x").safeRelativePath, ".disk/info")
        XCTAssertNil(ContentProbe(path: "../../etc/passwd", pattern: "x").safeRelativePath)
        XCTAssertNil(ContentProbe(path: ".disk/../../x", pattern: "x").safeRelativePath)
        XCTAssertNil(ContentProbe(path: "", pattern: "x").safeRelativePath)
        XCTAssertNil(ContentProbe(path: "/", pattern: "x").safeRelativePath)
    }

    func testAProbeWithAnUnsafePathIsSkippedNotRead() {
        var read: [String] = []
        let unsafe = ContentProbe(path: "../escape", pattern: #"(\d+)"#)
        let safe = ContentProbe(path: ".disk/info", pattern: #"^Debian GNU/Linux (\d+\.\d+\.\d+)"#)
        let version = ContentProbeRunner.version(probes: [unsafe, safe]) { path in
            read.append(path)
            return path == ".disk/info" ? self.debianInfo : "99"
        }
        XCTAssertEqual(read, [".disk/info"], "the unsafe path must never reach the reader")
        XCTAssertEqual(version?.raw, "13.6.0")
    }

    // MARK: - Codable

    func testCodableRoundTripAndDecodeDefaults() throws {
        let probes = [proxmoxProbe, debianProbe]
        let data = try JSONStore.makeEncoder().encode(probes)
        XCTAssertEqual(try JSONStore.makeDecoder().decode([ContentProbe].self, from: data), probes)

        // `versionTemplate` is optional in the JSON, and the whole list is
        // optional on an entry: a pre-F44 catalog must still decode.
        let json = Data(#"{"path":".disk/info","pattern":"^Debian GNU/Linux (\\d+\\.\\d+\\.\\d+)\\b"}"#.utf8)
        let decoded = try JSONStore.makeDecoder().decode(ContentProbe.self, from: json)
        XCTAssertEqual(decoded, debianProbe)
        XCTAssertNil(decoded.versionTemplate)
    }

    func testEntryWithoutProbesDecodesToAnEmptyList() throws {
        let json = Data("""
        {"id":"x","name":"X","kind":"linux","isBuiltIn":true,
         "channels":[{"id":"default","name":"Default",
                      "provider":{"mechanism":"staticURL","url":"https://example.invalid/x.iso"}}]}
        """.utf8)
        let entry = try JSONStore.makeDecoder().decode(CatalogEntry.self, from: json)
        XCTAssertEqual(entry.contentProbes, [])
        XCTAssertEqual(entry.contentProbes(forChannel: "default"), [])
        XCTAssertEqual(entry.contentProbes(forChannel: nil), [])
    }

    // MARK: - Channel override

    func testChannelProbesOverrideTheEntrysOwn() {
        let entry = CatalogEntry(
            id: "debian", name: "Debian", kind: .linux, organization: "Debian",
            channels: [
                Channel(id: "netinst", name: "netinst",
                        provider: .staticURL(url: URL(string: "https://example.invalid/x.iso")!,
                                             checksumURL: nil)),
                Channel(id: "dvd", name: "DVD",
                        provider: .staticURL(url: URL(string: "https://example.invalid/y.iso")!,
                                             checksumURL: nil),
                        contentProbes: [ContentProbe(path: ".disk/info", pattern: #"DVD-(\d+)"#)])
            ],
            isBuiltIn: true, contentProbes: [debianProbe])
        XCTAssertEqual(entry.contentProbes(forChannel: "netinst"), [debianProbe])
        XCTAssertEqual(entry.contentProbes(forChannel: "dvd").map(\.pattern), [#"DVD-(\d+)"#])
        XCTAssertEqual(entry.contentProbes(forChannel: "nonexistent"), [debianProbe])
        XCTAssertEqual(entry.contentProbes(forChannel: nil), [debianProbe])
    }

    // MARK: - The shipped catalog

    func testBundledCatalogProbesCompileAndParseTheRealMarkerFiles() throws {
        let entries = try Self.bundledCatalog()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        for entry in entries {
            for probe in entry.contentProbes {
                XCTAssertNotNil(probe.safeRelativePath, "\(entry.id): unsafe probe path")
                XCTAssertNoThrow(try PatternMatcher(probe.pattern), "\(entry.id): bad probe regex")
            }
        }

        // The three formats captured live from the published ISOs.
        let expectations: [(String, String, String)] = [
            ("proxmox-ve", proxmoxInfo, "9.2-1"),
            ("debian", debianInfo, "13.6.0"),
            ("ubuntu-desktop", ubuntuInfo, "24.04.4"),
            ("ubuntu-server",
             #"Ubuntu-Server 24.04.4 LTS "Noble Numbat" - Release amd64 (20260210)"#, "24.04.4"),
            ("kubuntu", #"Kubuntu 24.04.4 LTS "Noble Numbat" - Release amd64 (20260210)"#, "24.04.4"),
            ("xubuntu", #"Xubuntu 24.04.3 LTS "Noble Numbat" - Release amd64 (20250805.1)"#, "24.04.3"),
            ("lubuntu", #"Lubuntu 24.04.3 LTS "Noble Numbat" - Release amd64 (20250805.1)"#, "24.04.3"),
            ("ubuntu-mate",
             #"Ubuntu-MATE 24.04.3 LTS "Noble Numbat" - Release amd64 (20250805.1)"#, "24.04.3"),
            ("linux-mint-cinnamon", #"Linux Mint 22.3 "Zena" - Release amd64 20260108"#, "22.3")
        ]
        for (entryID, marker, expected) in expectations {
            guard let entry = byID[entryID] else { return XCTFail("no \(entryID) in the catalog") }
            let version = ContentProbeRunner.version(probes: entry.contentProbes,
                                                     read: reader([".disk/info": marker]))
            XCTAssertEqual(version?.raw, expected, "\(entryID) probe")
        }

        // Ubuntu 26.04 has no point release; the probe must still read it.
        XCTAssertEqual(ContentProbeRunner.version(
            probes: byID["ubuntu-desktop"]!.contentProbes,
            read: reader([".disk/info": #"Ubuntu 26.04 "Resolute Raccoon" - Release amd64 (20260423.1)"#])
        )?.raw, "26.04")
    }

    static func bundledCatalog() throws -> [CatalogEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IsotopeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // IsotopeCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Isotope/Resources/catalog.json")
        return try JSONStore.loadJSON([CatalogEntry].self, from: try Data(contentsOf: url))
    }
}
