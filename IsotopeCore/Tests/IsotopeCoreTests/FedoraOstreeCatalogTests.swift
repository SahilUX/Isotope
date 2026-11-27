import XCTest
@testable import IsotopeCore

/// Fedora Silverblue and Kinoite renamed their ISOs at 45
/// (`Fedora-Silverblue-ostree-x86_64-44-1.7.iso` became
/// `Fedora-Silverblue-Installer-45-1.4.x86_64.iso`) and their volume labels
/// (`Fedora-SB-ostree-x86_64-44` became `Fedora-45-Silverblue-x86_64`). The
/// entries must resolve and recognise both generations. These tests run the
/// real catalog entries against a releases.json fixture shaped like the live one.
final class FedoraOstreeCatalogTests: XCTestCase {
    private func bundledCatalog() throws -> [CatalogEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IsotopeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // IsotopeCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Isotope/Resources/catalog.json")
        return try JSONStore.loadJSON([CatalogEntry].self, from: try Data(contentsOf: url))
    }

    private func entry(_ id: String) throws -> CatalogEntry {
        let found = try bundledCatalog().first { $0.id == id }
        return try XCTUnwrap(found, "catalog has no \(id)")
    }

    // MARK: - Version resolution

    func testSilverblueAndKinoiteResolve45OverThe44OstreeISO() async throws {
        let expected: [(id: String, fileName: String, sha256Digit: Character)] = [
            ("fedora-silverblue", "Fedora-Silverblue-Installer-45-1.4.x86_64.iso", "7"),
            ("fedora-kinoite", "Fedora-Kinoite-Installer-45-1.4.x86_64.iso", "8"),
        ]
        for item in expected {
            let config = try XCTUnwrap(try entry(item.id).channels.first?.provider)
            guard case .jsonFeed(let url, _, _) = config else {
                return XCTFail("\(item.id) is not a jsonFeed entry")
            }
            let http = MockHTTPClient()
            http.stub(url.absoluteString, fixture: "fedora-ostree-releases.json")

            let release = try await JSONFeedProvider(http: http).fetchLatest(config: config)

            XCTAssertEqual(release.version, VersionToken.parse("45"), item.id)
            XCTAssertEqual(release.fileName, item.fileName, item.id)
            // The final 45 row, not the "45 Beta" row that carries the same file name.
            XCTAssertEqual(release.sha256, String(repeating: item.sha256Digit, count: 64), item.id)
            XCTAssertTrue(release.isoURL?.absoluteString.contains("/releases/45/") == true, item.id)
        }
    }

    /// Before the final 45 is published only the "45 Beta" row exists with the
    /// new file name. "45 Beta" is not a version, so it never wins: the entry
    /// stays on 44 until the release row appears.
    func testBetaRowsAreNeverTreatedAsTheRelease() async throws {
        let config = try XCTUnwrap(try entry("fedora-silverblue").channels.first?.provider)
        guard case .jsonFeed(let url, _, _) = config else { return XCTFail("not a jsonFeed entry") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(Fixtures.text("fedora-ostree-releases.json").utf8)) as? [[String: String]])
        let beforeRelease = rows.filter { $0["version"] != "45" }
        XCTAssertTrue(beforeRelease.contains { $0["version"] == "45 Beta" })
        let http = MockHTTPClient()
        http.stub(url.absoluteString,
                  text: String(decoding: try JSONSerialization.data(withJSONObject: beforeRelease),
                               as: UTF8.self))

        let release = try await JSONFeedProvider(http: http).fetchLatest(config: config)

        XCTAssertEqual(release.version, VersionToken.parse("44"))
        XCTAssertEqual(release.fileName, "Fedora-Silverblue-ostree-x86_64-44-1.7.iso")
    }

    // MARK: - File names (drive scan)

    func testBothFileNameGenerationsAreRecognisedWithTheirVersion() throws {
        let catalog = try bundledCatalog()
        let cases: [(fileName: String, entryID: String, version: String)] = [
            ("Fedora-Silverblue-ostree-x86_64-44-1.7.iso", "fedora-silverblue", "44"),
            ("Fedora-Silverblue-Installer-45-1.4.x86_64.iso", "fedora-silverblue", "45"),
            ("Fedora-Kinoite-ostree-x86_64-44-1.7.iso", "fedora-kinoite", "44"),
            ("Fedora-Kinoite-Installer-45-1.4.x86_64.iso", "fedora-kinoite", "45"),
        ]
        for item in cases {
            let detected = ISOContentMatcher.match(fileName: item.fileName, in: catalog)
            XCTAssertEqual(detected?.entryID, item.entryID, item.fileName)
            XCTAssertEqual(detected?.version, VersionToken.parse(item.version), item.fileName)
        }
    }

    // MARK: - Volume labels (flashed drives)

    /// The 44 labels are the ones a real 44 ISO carries, and the 45 labels are
    /// what the 45 ISOs' primary volume descriptors say.
    func testBothVolumeLabelGenerationsResolveToTheirEntryAndVersion() throws {
        let catalog = try bundledCatalog()
        let cases: [(label: String, entryID: String, version: String)] = [
            ("Fedora-SB-ostree-x86_64-44", "fedora-silverblue", "44"),
            ("Fedora-45-Silverblue-x86_64", "fedora-silverblue", "45"),
            ("Fedora-Knt-ostree-x86_64-44", "fedora-kinoite", "44"),
            ("Fedora-Kinoite-ostree-x86_64-43", "fedora-kinoite", "43"),
            ("Fedora-45-Kinoite-x86_64", "fedora-kinoite", "45"),
        ]
        for item in cases {
            let match = VolumeLabelMatcher.bestMatch(labels: [item.label], in: catalog)
            XCTAssertEqual(match?.entryID, item.entryID, item.label)
            XCTAssertEqual(match?.version, VersionToken.parse(item.version), item.label)
        }
    }

    func testOtherFedoraLabelsAreNotClaimedByTheOstreeEntries() throws {
        let silverblue = try entry("fedora-silverblue")
        let kinoite = try entry("fedora-kinoite")
        for label in ["Fedora-WS-Live-45", "Fedora-KDE-Desktop-Live-45", "Fedora-45-Workstation-x86_64"] {
            XCTAssertNil(VolumeLabelMatcher.match(label: label, entry: silverblue), label)
            XCTAssertNil(VolumeLabelMatcher.match(label: label, entry: kinoite), label)
        }
        // Silverblue and Kinoite do not swallow each other's labels either.
        XCTAssertNil(VolumeLabelMatcher.match(label: "Fedora-45-Kinoite-x86_64", entry: silverblue))
        XCTAssertNil(VolumeLabelMatcher.match(label: "Fedora-45-Silverblue-x86_64", entry: kinoite))
    }
}
