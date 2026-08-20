import XCTest
@testable import IsotopeCore

final class ProviderConfigCodableTests: XCTestCase {
    private let samples: [ProviderConfig] = [
        .checksumFile(url: URL(string: "https://releases.ubuntu.com/24.04/SHA256SUMS")!,
                      filePattern: #"ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso"#),
        .gitHubReleases(repo: "memtest86plus/memtest86plus", assetPattern: #".*\.iso$"#),
        .staticURL(url: URL(string: "https://example.org/latest/foo.iso")!, checksumURL: nil),
        .staticURL(url: URL(string: "https://example.org/latest/foo.iso")!,
                   checksumURL: URL(string: "https://example.org/latest/foo.iso.sha256")!),
        .staticURL(url: URL(string: "https://example.org/latest/foo.iso")!, checksumURL: nil,
                   fileNamePattern: #"^(?:latest-)?foo\.iso$"#),
        .pageScrape(url: URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/")!,
                    linkPattern: #"debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso"#),
        .windowsManual(infoURL: URL(string: "https://learn.microsoft.com/windows/release-health/")!,
                       downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11")!),
        .windowsManual(infoURL: URL(string: "https://learn.microsoft.com/windows/release-health/")!,
                       downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11")!,
                       versionPattern: #"\b(\d{5}\.\d+)\b"#),
        .windowsManual(infoURL: URL(string: "https://learn.microsoft.com/windows/release-health/")!,
                       downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11")!,
                       versionPattern: #"\b(\d{5}\.\d+)\b"#,
                       fileNamePattern: #"^Win11_.*\.iso$"#),
        // PRD F43: release token as the version, build number as display detail.
        .windowsManual(infoURL: URL(string: "https://www.microsoft.com/software-download/windows11")!,
                       downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11")!,
                       versionPattern: #"\bVersion (\d{2}H\d)\b"#,
                       fileNamePattern: #"^Win11(?:_(\d{2}H\d))?_.*\.iso$"#,
                       buildInfoURL: URL(string: "https://learn.microsoft.com/windows/release-health/")!,
                       buildPattern: #">{version}<[\s\S]{0,3000}?\b(\d{5}\.\d{1,5})\b"#),
        // Optional extensions: index step, explicit download base, checksum sidecar.
        .checksumFile(url: URL(string: "https://releases.ubuntu.com/24.04/SHA256SUMS")!,
                      filePattern: #"ubuntu-(\d+\.\d+)-desktop-amd64\.iso"#,
                      index: IndexStep(url: URL(string: "https://changelogs.ubuntu.com/meta-release-lts")!,
                                       pattern: #"Version: (\d+\.\d+)"#,
                                       target: "https://releases.ubuntu.com/{version}/SHA256SUMS"),
                      downloadBase: URL(string: "https://cdn.example/iso/")!),
        .pageScrape(url: URL(string: "https://www.system-rescue.org/Download/")!,
                    linkPattern: #"systemrescue-(\d+\.\d+)-amd64\.iso$"#,
                    checksumSuffix: ".sha256"),
        .jsonFeed(url: URL(string: "https://fedoraproject.org/releases.json")!,
                  spec: JSONFeedSpec(itemsPath: nil,
                                     filter: ["variant": "Workstation", "arch": "x86_64"],
                                     versionKeys: ["version"], isoURLKey: "link",
                                     sha256Key: "sha256", sizeKey: "size")),
        .jsonFeed(url: URL(string: "https://fedoraproject.org/releases.json")!,
                  spec: JSONFeedSpec(versionKeys: ["version"], isoURLKey: "link"),
                  fileNamePattern: #"^Fedora-Workstation-Live-(\d+)-[\d.]+\.x86_64\.iso$"#)
    ]

    func testRoundTripsPreserveCase() throws {
        for config in samples {
            let data = try JSONStore.makeEncoder().encode(config)
            let decoded = try JSONStore.makeDecoder().decode(ProviderConfig.self, from: data)
            XCTAssertEqual(decoded, config)
        }
    }

    func testEncodesDiscriminator() throws {
        for config in samples {
            let data = try JSONStore.makeEncoder().encode(config)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["mechanism"] as? String, config.mechanism.rawValue)
        }
    }

    func testDecodesHandWrittenJSON() throws {
        let json = """
        {"mechanism":"checksumFile","url":"https://example.org/SHA256SUMS","filePattern":"foo-(.*)\\\\.iso"}
        """
        let decoded = try JSONStore.makeDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        guard case .checksumFile(let url, let pattern, let index, let downloadBase) = decoded else {
            return XCTFail("wrong case: \(decoded)")
        }
        XCTAssertEqual(url.absoluteString, "https://example.org/SHA256SUMS")
        XCTAssertEqual(pattern, #"foo-(.*)\.iso"#)
        XCTAssertNil(index)
        XCTAssertNil(downloadBase)
    }

    func testDecodesHandWrittenJSONFeed() throws {
        let json = """
        {"mechanism":"jsonFeed","url":"https://example.org/releases.json",
         "filter":{"variant":"Workstation"},"versionKeys":["version"],
         "isoURLKey":"link","sha256Key":"sha256","sizeKey":"size"}
        """
        let decoded = try JSONStore.makeDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        guard case .jsonFeed(let url, let spec, _) = decoded else {
            return XCTFail("wrong case: \(decoded)")
        }
        XCTAssertEqual(url.absoluteString, "https://example.org/releases.json")
        XCTAssertEqual(spec.filter, ["variant": "Workstation"])
        XCTAssertEqual(spec.versionKeys, ["version"])
        XCTAssertNil(spec.itemsPath)
    }

    func testBundledCatalogDecodes() throws {
        // The catalog ships with the app; a typo in it must fail the test suite,
        // not the first launch. Path is relative to this file's package root.
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IsotopeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // IsotopeCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Isotope/Resources/catalog.json")
        let data = try Data(contentsOf: catalog)
        let entries = try JSONStore.loadJSON([CatalogEntry].self, from: data)
        XCTAssertGreaterThanOrEqual(entries.count, 13)
        XCTAssertTrue(entries.allSatisfy { $0.isBuiltIn && !$0.channels.isEmpty })
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "entry ids must be unique")
        for entry in entries {
            XCTAssertEqual(Set(entry.channels.map(\.id)).count, entry.channels.count,
                           "\(entry.id) has duplicate channel ids")
            for channel in entry.channels {
                // Every regex in the catalog must compile.
                switch channel.provider {
                case .checksumFile(_, let pattern, let index, _):
                    XCTAssertNoThrow(try PatternMatcher(pattern))
                    if let index { XCTAssertNoThrow(try PatternMatcher(index.pattern)) }
                case .pageScrape(_, let pattern, let index, _):
                    XCTAssertNoThrow(try PatternMatcher(pattern))
                    if let index { XCTAssertNoThrow(try PatternMatcher(index.pattern)) }
                case .gitHubReleases(_, let pattern):
                    XCTAssertNoThrow(try PatternMatcher(pattern))
                case .windowsManual(_, _, let versionPattern, let fileNamePattern, _, let buildPattern):
                    if let versionPattern { XCTAssertNoThrow(try PatternMatcher(versionPattern)) }
                    if let fileNamePattern { XCTAssertNoThrow(try PatternMatcher(fileNamePattern)) }
                    // PRD F43: `{version}` is substituted before compiling, so
                    // the stored pattern is only a regex once that is done.
                    if let buildPattern {
                        let resolved = buildPattern.replacingOccurrences(
                            of: WindowsInfoProvider.versionPlaceholder, with: "25H2")
                        XCTAssertNoThrow(try PatternMatcher(resolved))
                    }
                case .staticURL(_, _, let pattern), .jsonFeed(_, _, let pattern):
                    if let pattern { XCTAssertNoThrow(try PatternMatcher(pattern)) }
                }
            }
        }
    }

    func testUnknownMechanismFailsLoudly() {
        let json = #"{"mechanism":"torrent","url":"https://example.org/x.iso"}"#
        XCTAssertThrowsError(try JSONStore.makeDecoder().decode(ProviderConfig.self, from: Data(json.utf8)))
    }

    func testOmittedOptionalChecksumURL() throws {
        let json = #"{"mechanism":"staticURL","url":"https://example.org/x.iso"}"#
        let decoded = try JSONStore.makeDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .staticURL(url: URL(string: "https://example.org/x.iso")!, checksumURL: nil))
    }

    func testCatalogEntryRoundTrip() throws {
        let entry = CatalogEntry(
            id: "ubuntu-desktop",
            name: "Ubuntu Desktop",
            kind: .linux,
            homepage: URL(string: "https://ubuntu.com/download/desktop"),
            channels: [Channel(id: "lts", name: "LTS", provider: samples[0])],
            isBuiltIn: true
        )
        let data = try JSONStore.makeEncoder().encode([entry])
        let decoded = try JSONStore.makeDecoder().decode([CatalogEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }
}
