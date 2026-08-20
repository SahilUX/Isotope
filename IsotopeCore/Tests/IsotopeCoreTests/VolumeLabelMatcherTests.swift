import XCTest
@testable import IsotopeCore

/// PRD F40: the pure label → catalog matcher, driven by the volume identifiers
/// actually read out of the published ISOs' ISO-9660 primary volume descriptors.
final class VolumeLabelMatcherTests: XCTestCase {
    // MARK: - Fixtures

    private func channel(_ id: String, label: String? = nil) -> Channel {
        Channel(id: id, name: id,
                provider: .checksumFile(url: URL(string: "https://example.invalid/SHA256SUMS")!,
                                        filePattern: "^x-(\\d+)\\.iso$"),
                volumeLabelPattern: label)
    }

    private var ubuntu: CatalogEntry {
        CatalogEntry(id: "ubuntu-desktop", name: "Ubuntu Desktop", kind: .linux,
                     organization: "Ubuntu",
                     channels: [channel("lts"), channel("latest")], isBuiltIn: true,
                     volumeLabelPattern: "^Ubuntu (\\d+\\.\\d+(?:\\.\\d+)?)(?: LTS)? amd64")
    }

    private var kubuntu: CatalogEntry {
        CatalogEntry(id: "kubuntu", name: "Kubuntu", kind: .linux, organization: "Ubuntu",
                     channels: [channel("lts")], isBuiltIn: true,
                     volumeLabelPattern: "^Kubuntu (\\d+\\.\\d+(?:\\.\\d+)?)(?: LTS)? amd64")
    }

    private var mate: CatalogEntry {
        CatalogEntry(id: "ubuntu-mate", name: "Ubuntu MATE", kind: .linux, organization: "Ubuntu",
                     channels: [channel("lts")], isBuiltIn: true,
                     volumeLabelPattern: "^Ubuntu-MATE (\\d+\\.\\d+(?:\\.\\d+)?)(?: LTS)? amd64")
    }

    private var fedora: CatalogEntry {
        CatalogEntry(id: "fedora-workstation", name: "Fedora Workstation", kind: .linux,
                     organization: "Fedora", channels: [channel("default")], isBuiltIn: true,
                     volumeLabelPattern: "^Fedora-WS-Live-(\\d+)")
    }

    private var debian: CatalogEntry {
        CatalogEntry(id: "debian", name: "Debian", kind: .linux, organization: "Debian",
                     channels: [channel("netinst", label: "^Debian (\\d+\\.\\d+\\.\\d+) amd64 n"),
                                channel("dvd", label: "^Debian (\\d+\\.\\d+\\.\\d+) amd64 1")],
                     isBuiltIn: true,
                     volumeLabelPattern: "^Debian (\\d+\\.\\d+\\.\\d+) amd64")
    }

    /// Labels with no version in them at all (PRD F40: identify, do not invent).
    private var proxmox: CatalogEntry {
        CatalogEntry(id: "proxmox-ve", name: "Proxmox VE", kind: .linux, organization: "Proxmox",
                     channels: [channel("default")], isBuiltIn: true,
                     volumeLabelPattern: "^PVE$")
    }

    /// No pattern at all — never matches anything.
    private var memtest: CatalogEntry {
        CatalogEntry(id: "memtest86plus", name: "Memtest86+", kind: .tool,
                     organization: "Tools & rescue", channels: [channel("default")],
                     isBuiltIn: true)
    }

    private var catalog: [CatalogEntry] {
        [ubuntu, kubuntu, mate, fedora, debian, proxmox, memtest]
    }

    // MARK: - Table

    func testRealWorldLabelsResolveToTheirEntryAndVersion() {
        let cases: [(label: String, entryID: String, version: String?)] = [
            ("Ubuntu 24.04.4 LTS amd64", "ubuntu-desktop", "24.04.4"),
            ("Ubuntu 26.04 amd64", "ubuntu-desktop", "26.04"),
            ("Kubuntu 24.04.4 LTS amd64", "kubuntu", "24.04.4"),
            ("Ubuntu-MATE 24.04.4 LTS amd64", "ubuntu-mate", "24.04.4"),
            ("Fedora-WS-Live-44", "fedora-workstation", "44"),
            ("Debian 13.6.0 amd64 n", "debian", "13.6.0"),
            ("PVE", "proxmox-ve", nil),
        ]
        for testCase in cases {
            guard let match = VolumeLabelMatcher.bestMatch(labels: [testCase.label], in: catalog) else {
                return XCTFail("no match for \(testCase.label)")
            }
            XCTAssertEqual(match.entryID, testCase.entryID, testCase.label)
            XCTAssertEqual(match.version?.raw, testCase.version, testCase.label)
        }
    }

    /// The flavour patterns are anchored, so the parent must not swallow them.
    func testFlavourLabelsDoNotMatchUbuntuDesktop() {
        XCTAssertNil(VolumeLabelMatcher.match(label: "Kubuntu 24.04.4 LTS amd64", entry: ubuntu))
        XCTAssertNil(VolumeLabelMatcher.match(label: "Ubuntu-MATE 24.04.4 LTS amd64", entry: ubuntu))
        XCTAssertEqual(VolumeLabelMatcher.matches(label: "Kubuntu 24.04.4 LTS amd64",
                                                  in: catalog).map(\.entryID), ["kubuntu"])
    }

    func testChannelPatternWinsOverEntryPattern() {
        let netinst = VolumeLabelMatcher.bestMatch(labels: ["Debian 13.6.0 amd64 n"], in: catalog)
        XCTAssertEqual(netinst?.channelID, "netinst")
        let dvd = VolumeLabelMatcher.bestMatch(labels: ["Debian 13.6.0 amd64 1"], in: catalog)
        XCTAssertEqual(dvd?.channelID, "dvd")
        // A Debian label that fits neither channel still identifies the entry.
        let bare = VolumeLabelMatcher.bestMatch(labels: ["Debian 13.6.0 amd64"], in: catalog)
        XCTAssertEqual(bare?.entryID, "debian")
        XCTAssertNil(bare?.channelID)
    }

    func testNoMatchCases() {
        XCTAssertNil(VolumeLabelMatcher.bestMatch(labels: [], in: catalog))
        XCTAssertNil(VolumeLabelMatcher.bestMatch(labels: [""], in: catalog))
        XCTAssertNil(VolumeLabelMatcher.bestMatch(labels: ["Untitled"], in: catalog))
        XCTAssertNil(VolumeLabelMatcher.bestMatch(labels: ["SANDISK 64GB"], in: catalog))
        // An entry with no pattern is never claimed, whatever the label says.
        XCTAssertNil(VolumeLabelMatcher.match(label: "Memtest86+", entry: memtest))
    }

    func testAmbiguousLabelsAreNotGuessed() {
        // Two entries, both of which match: a Ventoy stick with several volumes,
        // or an overlapping pattern. Nothing may be preselected.
        XCTAssertNil(VolumeLabelMatcher.bestMatch(
            labels: ["Ubuntu 24.04.4 LTS amd64", "Fedora-WS-Live-44"], in: catalog))
    }

    func testSeveralLabelsOfTheSameEntryPickTheRichestMatch() {
        let match = VolumeLabelMatcher.bestMatch(labels: ["Debian 13.6.0 amd64",
                                                          "Debian 13.6.0 amd64 n"], in: catalog)
        XCTAssertEqual(match?.entryID, "debian")
        XCTAssertEqual(match?.channelID, "netinst")
        XCTAssertEqual(match?.version?.raw, "13.6.0")
    }

    // MARK: - Attach-time re-check

    func testRecordedEntryStillMatchesWithANewVersion() {
        let match = VolumeLabelMatcher.match(labels: ["Ubuntu 26.04 amd64"], entry: ubuntu,
                                             channelID: "latest")
        XCTAssertEqual(match?.version, VersionToken.parse("26.04"))
    }

    func testRecordedEntryNoLongerMatches() {
        XCTAssertNil(VolumeLabelMatcher.match(labels: ["Fedora-WS-Live-44"], entry: ubuntu,
                                              channelID: "lts"))
        XCTAssertNil(VolumeLabelMatcher.match(labels: [], entry: ubuntu, channelID: "lts"))
    }

    func testChannelMismatchIsNotTreatedAsTheSameChannel() {
        // The stick says DVD, the record says netinst: not a version bump.
        XCTAssertNil(VolumeLabelMatcher.match(labels: ["Debian 13.6.0 amd64 1"], entry: debian,
                                              channelID: "netinst"))
        XCTAssertEqual(VolumeLabelMatcher.match(labels: ["Debian 13.6.0 amd64 1"], entry: debian,
                                                channelID: "dvd")?.version?.raw, "13.6.0")
    }

    // MARK: - Version shapes that need to compare equal to the resolved release

    func testHyphenatedLabelVersionsCompareEqualToDottedReleaseVersions() {
        // Rocky's label is "Rocky-10-2-x86_64-dvd" while its release is "10.2".
        let rocky = CatalogEntry(id: "rocky-linux", name: "Rocky Linux", kind: .linux,
                                 organization: "Enterprise Linux", channels: [channel("minimal")],
                                 isBuiltIn: true,
                                 volumeLabelPattern: "^Rocky-(\\d+-\\d+)-x86_64")
        let match = VolumeLabelMatcher.match(label: "Rocky-10-2-x86_64-dvd", entry: rocky)
        XCTAssertEqual(match?.version, VersionToken.parse("10.2"))
    }

    // MARK: - Grouping (PRD F38)

    func testGroupingKeepsCatalogOrder() {
        let groups = catalog.groupedByOrganization()
        XCTAssertEqual(groups.map(\.organization),
                       ["Ubuntu", "Fedora", "Debian", "Proxmox", "Tools & rescue"])
        XCTAssertEqual(groups[0].entries.map(\.id), ["ubuntu-desktop", "kubuntu", "ubuntu-mate"])
    }

    func testEntriesWithoutAnOrganizationDecodeToASensibleDefault() throws {
        let json = """
        [{"id":"custom-1","name":"My ISO","kind":"custom","isBuiltIn":false,
          "channels":[{"id":"default","name":"Stable",
            "provider":{"mechanism":"staticURL","url":"https://example.invalid/x.iso"}}]},
         {"id":"legacy","name":"Legacy Built-in","kind":"linux","isBuiltIn":true,
          "channels":[{"id":"default","name":"Stable",
            "provider":{"mechanism":"staticURL","url":"https://example.invalid/y.iso"}}]}]
        """
        let entries = try JSONStore.loadJSON([CatalogEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries[0].organization, "Custom")
        XCTAssertEqual(entries[1].organization, "Legacy Built-in")
        XCTAssertNil(entries[0].volumeLabelPattern)
    }
}
