import XCTest
@testable import IsotopeCore

final class ChecksumFileProviderTests: XCTestCase {
    private let sumsURL = "https://releases.example/24.04/SHA256SUMS"

    func testPicksHighestMatchingVersionWithHashAndSiblingURL() async throws {
        let http = MockHTTPClient()
        http.stub(sumsURL, fixture: "ubuntu-SHA256SUMS.txt")
        let release = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
            url: URL(string: sumsURL)!,
            filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#))

        XCTAssertEqual(release.version.raw, "24.04.4")
        XCTAssertEqual(release.fileName, "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertEqual(release.sha256, "3a4c9877b483ab46d7c3fbe165a0db275e1ae3cfe56a5657e5a47c2f99a99d1e")
        XCTAssertEqual(release.isoURL?.absoluteString,
                       "https://releases.example/24.04/ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(release.isVerifiable)
    }

    func testDownloadBaseOverridesSiblingResolution() async throws {
        let http = MockHTTPClient()
        http.stub("https://gparted.example/CHECKSUMS.TXT", fixture: "gparted-CHECKSUMS.TXT")
        let release = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
            url: URL(string: "https://gparted.example/CHECKSUMS.TXT")!,
            filePattern: #"^gparted-live-(\d+\.\d+\.\d+-\d+)-amd64\.iso$"#,
            downloadBase: URL(string: "https://cdn.example/gparted/")!))

        XCTAssertEqual(release.version.raw, "1.8.1-3")
        XCTAssertEqual(release.isoURL?.absoluteString,
                       "https://cdn.example/gparted/gparted-live-1.8.1-3-amd64.iso")
    }

    func testIndexStepResolvesSeriesBeforeFetchingSums() async throws {
        let http = MockHTTPClient()
        http.stub("https://changelogs.example/meta-release", fixture: "meta-release.txt")
        http.stub(sumsURL, fixture: "ubuntu-SHA256SUMS.txt")
        let index = IndexStep(url: URL(string: "https://changelogs.example/meta-release")!,
                              pattern: #"Version: (\d+\.\d+)[^\n]*\nDate:[^\n]*\nSupported: 1"#,
                              target: "https://releases.example/{version}/SHA256SUMS")
        let release = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
            url: URL(string: "https://unused.example/SHA256SUMS")!,
            filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#,
            index: index))

        // 24.04 is supported and beats 22.04; the unsupported 24.10 is ignored.
        XCTAssertEqual(http.requestedGETs.map(\.absoluteString),
                       ["https://changelogs.example/meta-release", sumsURL])
        XCTAssertEqual(release.version.raw, "24.04.4")
    }

    func testNoMatchReportsPatternAndSnippet() async {
        let http = MockHTTPClient()
        http.stub(sumsURL, fixture: "ubuntu-SHA256SUMS.txt")
        do {
            _ = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
                url: URL(string: sumsURL)!, filePattern: #"^nothing-(\d+)\.iso$"#))
            XCTFail("expected a no-match error")
        } catch let error as ProviderError {
            guard case .noMatch(let pattern, _, let snippet) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(pattern, #"^nothing-(\d+)\.iso$"#)
            XCTAssertTrue(snippet.contains("ubuntu-24.04.3-desktop-amd64.iso"))
            XCTAssertTrue(error.errorDescription?.contains("matched") == true)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testHTTPFailureSurfacesStatus() async {
        let http = MockHTTPClient()
        http.stub(sumsURL, text: "nope", statusCode: 503)
        do {
            _ = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
                url: URL(string: sumsURL)!, filePattern: #"(\d+)"#))
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .httpStatus(503, URL(string: sumsURL)!))
        }
    }

    func testInvalidRegexIsReportedNotCrashed() async {
        let http = MockHTTPClient()
        http.stub(sumsURL, fixture: "ubuntu-SHA256SUMS.txt")
        do {
            _ = try await ChecksumFileProvider(http: http).fetchLatest(config: .checksumFile(
                url: URL(string: sumsURL)!, filePattern: "([unclosed"))
            XCTFail("expected an invalid-regex error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .invalidRegex("([unclosed"))
        }
    }
}

final class GitHubReleasesProviderTests: XCTestCase {
    private let listURL = "https://api.github.com/repos/memtest86plus/memtest86plus/releases?per_page=20"
    private let digest = "3f66b2e10b8bb2c573ed6cdd3a9b54fd0a8e7690634ab6b15c3c8f517992d1a1"

    func testSkipsPrereleasesAndUsesSiblingChecksumAsset() async throws {
        let http = MockHTTPClient()
        http.stub(listURL, fixture: "github-releases.json")
        http.stub("https://example.test/mt86plus_8.10_x86_64.iso.sha256", text: digest + "\n")

        let release = try await GitHubReleasesProvider(http: http).fetchLatest(config: .gitHubReleases(
            repo: "memtest86plus/memtest86plus", assetPattern: #"_x86_64\.iso$"#))

        XCTAssertEqual(release.version.raw, "8.10")      // v-prefix stripped, beta skipped
        XCTAssertEqual(release.fileName, "mt86plus_8.10_x86_64.iso")
        XCTAssertEqual(release.sizeBytes, 2_097_152)
        XCTAssertEqual(release.sha256, digest)
    }

    func testSendsUserAgentHeader() async throws {
        let http = MockHTTPClient()
        http.stub(listURL, fixture: "github-releases.json")
        _ = try? await GitHubReleasesProvider(http: http).fetchLatest(config: .gitHubReleases(
            repo: "memtest86plus/memtest86plus", assetPattern: #"_x86_64\.iso$"#))
        XCTAssertNotNil(http.lastHeaders["User-Agent"])
    }

    func testMissingChecksumAssetLeavesReleaseUnverified() async throws {
        let http = MockHTTPClient()
        http.stub(listURL, fixture: "github-releases.json")   // sidecar deliberately not stubbed
        let release = try await GitHubReleasesProvider(http: http).fetchLatest(config: .gitHubReleases(
            repo: "memtest86plus/memtest86plus", assetPattern: #"_x86_64\.iso$"#))
        XCTAssertNil(release.sha256)
        XCTAssertFalse(release.isVerifiable)
    }

    func testNoAssetMatchesPattern() async {
        let http = MockHTTPClient()
        http.stub(listURL, fixture: "github-releases.json")
        do {
            _ = try await GitHubReleasesProvider(http: http).fetchLatest(config: .gitHubReleases(
                repo: "memtest86plus/memtest86plus", assetPattern: #"\.dmg$"#))
            XCTFail("expected a no-match error")
        } catch {
            guard case .noMatch = (error as? ProviderError) else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}

final class StaticURLProviderTests: XCTestCase {
    private let isoURL = URL(string: "https://example.test/latest/foo.iso")!

    func testLastModifiedBecomesChangeDate() async throws {
        let http = MockHTTPClient()
        http.stubHead(isoURL.absoluteString, headers: [
            "Last-Modified": "Tue, 04 Aug 2026 11:22:33 GMT",
            "Content-Length": "4096",
            "ETag": "\"abc123\""
        ])
        let release = try await StaticURLProvider(http: http)
            .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))

        XCTAssertEqual(release.version.raw, "2026-08-04")
        guard case .date = release.version else { return XCTFail("expected a date token") }
        XCTAssertEqual(release.sizeBytes, 4096)
        XCTAssertEqual(release.fileName, "foo.iso")
        XCTAssertEqual(release.isoURL, isoURL)
    }

    func testFallsBackToETagThenLength() async throws {
        let http = MockHTTPClient()
        http.stubHead(isoURL.absoluteString, headers: ["ETag": "\"W/etag-9\"", "Content-Length": "10"])
        let etagRelease = try await StaticURLProvider(http: http)
            .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))
        XCTAssertEqual(etagRelease.version.raw, "etag-9")

        let bare = MockHTTPClient()
        bare.stubHead(isoURL.absoluteString, headers: ["Content-Length": "10"])
        let sizeRelease = try await StaticURLProvider(http: bare)
            .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))
        XCTAssertEqual(sizeRelease.version.raw, "10 bytes")
    }

    func testUnchangedSignatureKeepsPreviousChangeDate() async throws {
        let http = MockHTTPClient()
        http.stubHead(isoURL.absoluteString, headers: ["ETag": "\"etag-9\""])
        let first = try await StaticURLProvider(http: http)
            .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))
        try await Task.sleep(nanoseconds: 2_000_000)
        let second = try await StaticURLProvider(http: http)
            .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))

        XCTAssertNotEqual(first.version, second.version, "raw dates differ before carry-over")
        XCTAssertEqual(second.carryingOverChangeDate(from: first).version, first.version)
    }

    func testChecksumURLIsUsedWhenProvided() async throws {
        let digest = "3f66b2e10b8bb2c573ed6cdd3a9b54fd0a8e7690634ab6b15c3c8f517992d1a1"
        let http = MockHTTPClient()
        http.stubHead(isoURL.absoluteString, headers: ["Last-Modified": "Tue, 04 Aug 2026 11:22:33 GMT"])
        http.stub("https://example.test/latest/SHA256SUMS", text: "\(digest)  foo.iso\n")
        let release = try await StaticURLProvider(http: http).fetchLatest(config: .staticURL(
            url: isoURL, checksumURL: URL(string: "https://example.test/latest/SHA256SUMS")!))
        XCTAssertEqual(release.sha256, digest)
    }

    func testNonSuccessStatusFails() async {
        let http = MockHTTPClient()
        http.stubHead(isoURL.absoluteString, headers: [:], statusCode: 404)
        do {
            _ = try await StaticURLProvider(http: http)
                .fetchLatest(config: .staticURL(url: isoURL, checksumURL: nil))
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .httpStatus(404, isoURL))
        }
    }
}

final class PageScrapeProviderTests: XCTestCase {
    private let pageURL = URL(string: "https://cdimage.example/debian-cd/current/amd64/iso-cd/")!

    func testPicksHighestAnchorAndResolvesRelativeHref() async throws {
        let http = MockHTTPClient()
        http.stub(pageURL.absoluteString, fixture: "directory-listing.html")
        let release = try await PageScrapeProvider(http: http).fetchLatest(config: .pageScrape(
            url: pageURL, linkPattern: #"^debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso$"#))

        XCTAssertEqual(release.version.raw, "13.6.0")
        XCTAssertEqual(release.isoURL?.absoluteString,
                       "https://cdimage.example/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso")
        XCTAssertNil(release.sha256, "a scrape without a checksum sidecar is unverified (PRD F21)")
    }

    func testChecksumSuffixFetchesSidecar() async throws {
        let digest = "3f66b2e10b8bb2c573ed6cdd3a9b54fd0a8e7690634ab6b15c3c8f517992d1a1"
        let http = MockHTTPClient()
        http.stub(pageURL.absoluteString, fixture: "directory-listing.html")
        http.stub("https://cdimage.example/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso.sha256",
                  text: digest)
        let release = try await PageScrapeProvider(http: http).fetchLatest(config: .pageScrape(
            url: pageURL, linkPattern: #"^debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso$"#,
            checksumSuffix: ".sha256"))
        XCTAssertEqual(release.sha256, digest)
    }

    func testRegexMatchingNothingReportsSnippet() async {
        let http = MockHTTPClient()
        http.stub(pageURL.absoluteString, fixture: "directory-listing.html")
        do {
            _ = try await PageScrapeProvider(http: http).fetchLatest(config: .pageScrape(
                url: pageURL, linkPattern: #"^fedora-(\d+)\.iso$"#))
            XCTFail("expected a no-match error")
        } catch {
            guard case .noMatch(_, _, let snippet) = (error as? ProviderError) else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(snippet.contains("Index of"))
        }
    }
}

final class JSONFeedProviderTests: XCTestCase {
    func testFedoraFilterSelectsVariantArchAndHighestVersion() async throws {
        let http = MockHTTPClient()
        http.stub("https://fedora.example/releases.json", fixture: "fedora-releases.json")
        let spec = JSONFeedSpec(filter: ["variant": "Workstation", "subvariant": "Workstation",
                                         "arch": "x86_64"],
                                versionKeys: ["version"], isoURLKey: "link",
                                sha256Key: "sha256", sizeKey: "size")
        let release = try await JSONFeedProvider(http: http).fetchLatest(config: .jsonFeed(
            url: URL(string: "https://fedora.example/releases.json")!, spec: spec))

        XCTAssertEqual(release.version.raw, "44")
        XCTAssertEqual(release.fileName, "Fedora-Workstation-Live-44-1.7.x86_64.iso")
        XCTAssertEqual(release.sha256, "1620295f6a00c27c3208f0c00b8ece4eab1ec69b9002152d97488bf26a426ddf")
        XCTAssertEqual(release.sizeBytes, 2_851_612_672)   // string-typed size is coerced
    }

    func testTailsNestedPathsAndItemsPath() async throws {
        let http = MockHTTPClient()
        http.stub("https://tails.example/latest.json", fixture: "tails-latest.json")
        let spec = JSONFeedSpec(itemsPath: "installations", versionKeys: ["version"],
                                isoURLKey: "installation-paths.[type=iso].target-files.0.url",
                                sha256Key: "installation-paths.[type=iso].target-files.0.sha256",
                                sizeKey: "installation-paths.[type=iso].target-files.0.size")
        let release = try await JSONFeedProvider(http: http).fetchLatest(config: .jsonFeed(
            url: URL(string: "https://tails.example/latest.json")!, spec: spec))

        XCTAssertEqual(release.version.raw, "7.10.1")
        XCTAssertEqual(release.fileName, "tails-amd64-7.10.1.iso")
        XCTAssertEqual(release.sizeBytes, 1_862_719_488)
    }

    func testObjectRootIsTreatedAsSingleReleaseAndVersionKeysJoin() async throws {
        let http = MockHTTPClient()
        http.stub("https://pop.example/builds/24.04/intel", text: """
        {"version":"24.04","url":"https://iso.example/pop-os_24.04_amd64_intel_20.iso",
         "size":2955067392,"sha_sum":"a0ef3842ab710db4f4407cf3499560b59dddbbcd59bee17beab7b0e99dc22b4c",
         "build":"20"}
        """)
        let spec = JSONFeedSpec(versionKeys: ["version", "build"], isoURLKey: "url",
                                sha256Key: "sha_sum", sizeKey: "size")
        let release = try await JSONFeedProvider(http: http).fetchLatest(config: .jsonFeed(
            url: URL(string: "https://pop.example/builds/24.04/intel")!, spec: spec))

        XCTAssertEqual(release.version.raw, "24.04.20")
        XCTAssertEqual(release.version.numericComponents, [24, 4, 20])
    }

    func testFilterMatchingNothingFails() async {
        let http = MockHTTPClient()
        http.stub("https://fedora.example/releases.json", fixture: "fedora-releases.json")
        let spec = JSONFeedSpec(filter: ["variant": "Nonexistent"], versionKeys: ["version"])
        do {
            _ = try await JSONFeedProvider(http: http).fetchLatest(config: .jsonFeed(
                url: URL(string: "https://fedora.example/releases.json")!, spec: spec))
            XCTFail("expected a no-match error")
        } catch {
            guard case .noMatch = (error as? ProviderError) else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}

final class WindowsInfoProviderTests: XCTestCase {
    private let infoURL = URL(string: "https://learn.example/windows11-release-information")!
    private let downloadPage = URL(string: "https://www.microsoft.example/software-download/windows11")!

    private let buildURL = URL(string: "https://learn.example/release-health/windows11")!

    /// PRD F43: the resolved version is the feature release, not the build.
    func testResolvesFeatureReleaseAndLeavesISOURLNil() async throws {
        let http = MockHTTPClient()
        http.stub(infoURL.absoluteString, text: """
        <h1>Download Windows 11</h1><p>(Current release: Windows 11 2025 Update l Version 25H2)</p>
        """)
        let release = try await WindowsInfoProvider(http: http).fetchLatest(config: .windowsManual(
            infoURL: infoURL, downloadPage: downloadPage))

        XCTAssertEqual(release.version, .windowsRelease(year: 25, half: 2, raw: "25H2"))
        XCTAssertNil(release.displayDetail)
        XCTAssertEqual(release.displayVersion, "25H2")
        // PRD §5.4: no stable hotlink exists, so the download stays manual.
        XCTAssertNil(release.isoURL)
        XCTAssertEqual(release.fileName, "")
        XCTAssertFalse(release.isVerifiable)
    }

    /// PRD F43: the build number is fetched separately and only ever displayed.
    func testBuildNumberBecomesDisplayDetail() async throws {
        let http = MockHTTPClient()
        http.stub(infoURL.absoluteString, text: "Version 25H2")
        http.stub(buildURL.absoluteString, text: """
        <tr><td>26H1</td><td>2026-02-10</td><td>28000.2704</td></tr>
        <tr><td>25H2</td><td>2025-09-30</td><td>26200.9168</td></tr>
        """)
        let release = try await WindowsInfoProvider(http: http).fetchLatest(config: .windowsManual(
            infoURL: infoURL, downloadPage: downloadPage, buildInfoURL: buildURL,
            buildPattern: #">{version}<[\s\S]{0,3000}?\b(\d{5}\.\d{1,5})\b"#))

        // The build belonging to 25H2 — not 26H1's, which sits higher up the page.
        XCTAssertEqual(release.version.raw, "25H2")
        XCTAssertEqual(release.displayDetail, "build 26200.9168")
        XCTAssertEqual(release.displayVersion, "25H2 (build 26200.9168)")
    }

    /// A cosmetic detail must never fail a check.
    func testUnreachableBuildPageLeavesTheDetailOff() async throws {
        let http = MockHTTPClient()
        http.stub(infoURL.absoluteString, text: "Version 22H2")
        let release = try await WindowsInfoProvider(http: http).fetchLatest(config: .windowsManual(
            infoURL: infoURL, downloadPage: downloadPage, buildInfoURL: buildURL,
            buildPattern: #">{version}<[\s\S]*?\b(\d{5}\.\d{1,5})\b"#))
        XCTAssertEqual(release.version.raw, "22H2")
        XCTAssertNil(release.displayDetail)
    }

    func testUnrecognisedPageFails() async {
        let http = MockHTTPClient()
        http.stub(infoURL.absoluteString, text: "<html>no builds here</html>")
        do {
            _ = try await WindowsInfoProvider(http: http).fetchLatest(config: .windowsManual(
                infoURL: infoURL, downloadPage: downloadPage))
            XCTFail("expected a no-match error")
        } catch {
            guard case .noMatch = (error as? ProviderError) else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}

final class VersionResolverTests: XCTestCase {
    func testEachMechanismMapsToItsProvider() {
        let resolver = VersionResolver(http: MockHTTPClient())
        let url = URL(string: "https://example.test/x")!
        let pairs: [(ProviderConfig, Any.Type)] = [
            (.checksumFile(url: url, filePattern: "x"), ChecksumFileProvider.self),
            (.gitHubReleases(repo: "a/b", assetPattern: "x"), GitHubReleasesProvider.self),
            (.staticURL(url: url, checksumURL: nil), StaticURLProvider.self),
            (.pageScrape(url: url, linkPattern: "x"), PageScrapeProvider.self),
            (.jsonFeed(url: url, spec: JSONFeedSpec(versionKeys: ["v"])), JSONFeedProvider.self),
            (.windowsManual(infoURL: url, downloadPage: url), WindowsInfoProvider.self)
        ]
        for (config, expected) in pairs {
            XCTAssertTrue(type(of: resolver.provider(for: config)) == expected,
                          "\(config.mechanism) mapped to \(type(of: resolver.provider(for: config)))")
        }
        XCTAssertEqual(Set(pairs.map { $0.0.mechanism }), Set(ProviderConfig.Mechanism.allCases))
    }
}
