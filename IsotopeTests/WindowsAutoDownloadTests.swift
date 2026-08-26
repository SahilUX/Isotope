import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F49: the opt-in attempt at fetching a Windows ISO without the browser.
///
/// No network here — the resolver's parsing is exercised against real response
/// shapes (including the rejection Microsoft actually returns), and the store
/// path is driven through an injected resolver.
@MainActor
final class WindowsAutoDownloadTests: XCTestCase {
    private var root: URL!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeWinAutoTests-\(UUID().uuidString)")
        defaultsName = "IsotopeWinAutoTests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
    }

    // MARK: - The setting

    func testTheAttemptIsOffByDefault() {
        // Microsoft refuses it far more often than not; nobody should discover
        // that through a spinner they did not ask for.
        XCTAssertFalse(settings().attemptWindowsAutoDownload)
    }

    // MARK: - Parsing what comes back

    func testFindsTheISOLinkAndItsChecksumWhateverTheFieldsAreCalled() throws {
        // The field names have changed more than once; the shapes have not.
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"ProductDownloadOptions":[
          {"Uri":"https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64v2.iso?t=abc",
           "Sha1":"0000000000000000000000000000000000000000",
           "Sha256":"9F2C1A5B3D4E6F708192A3B4C5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8",
           "DownloadType":0}],
         "Errors":null}
        """.utf8))
        let resolved = try XCTUnwrap(WindowsDownloadResolver.download(in: json))
        XCTAssertEqual(resolved.fileName, "Win11_25H2_English_x64v2.iso")
        XCTAssertEqual(resolved.url.host, "software.download.prss.microsoft.com")
        // Lower-cased, because that is how every other checksum in the app is
        // stored and compared.
        XCTAssertEqual(resolved.sha256, "9f2c1a5b3d4e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8")
    }

    func testTheRejectionMicrosoftActuallyReturnsYieldsNothing() throws {
        // Observed verbatim while testing this feature against the live service.
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"Errors":[{"Key":"ErrorSettings.SentinelReject",
                    "Value":"Sentinel marked this request as rejected.","Type":8}]}
        """.utf8))
        XCTAssertNil(WindowsDownloadResolver.download(in: json))
    }

    func testALinkWithNoChecksumIsStillUsableButUnverified() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"ProductDownloadOptions":[{"Uri":"https://software.download.prss.microsoft.com/x/Win11_25H2_English_x64.iso"}]}
        """.utf8))
        let resolved = try XCTUnwrap(WindowsDownloadResolver.download(in: json))
        XCTAssertNil(resolved.sha256)
    }

    func testNonISOLinksAreIgnored() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"Links":[{"Uri":"https://www.microsoft.com/terms.html"},
                  {"Uri":"https://software.download.prss.microsoft.com/x/Win11_25H2_English_x64.iso"}]}
        """.utf8))
        XCTAssertEqual(try XCTUnwrap(WindowsDownloadResolver.download(in: json)).fileName,
                       "Win11_25H2_English_x64.iso")
    }

    func testPicksTheWantedLanguagesSKU() {
        let body = Data("""
        {"Skus":[{"Id":"20035","Language":"Arabic","ProductDisplayName":"Windows 11 25H2__V2"},
                 {"Id":"20046","Language":"English","ProductDisplayName":"Windows 11 25H2__V2"}]}
        """.utf8)
        XCTAssertEqual(WindowsDownloadResolver.skuID(inResponse: body, language: "English"), "20046")
        XCTAssertNil(WindowsDownloadResolver.skuID(inResponse: Data("{}".utf8), language: "English"))
    }

    // MARK: - Through the store

    private func makeStore(autoDownload: Bool, resolver: WindowsDownloadResolving) async -> AppStore {
        let settings = settings()
        settings.attemptWindowsAutoDownload = autoDownload
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil,
                             settings: settings)
        store.windowsResolver = resolver
        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows,
            channels: [Channel(id: "default", name: "Current release", provider: .windowsManual(
                infoURL: URL(string: "https://microsoft.invalid/w11")!,
                downloadPage: URL(string: "https://microsoft.invalid/w11")!,
                fileNamePattern: #"^Win11_(\d{2}H\d)_[A-Za-z]+_x64(?:_?v\d+)?\.iso$"#,
                mediaCatalog: WindowsMediaCatalog(
                    url: URL(string: "https://microsoft.invalid/api")!,
                    productEditionID: "3321")))],
            isBuiltIn: false))
        return store
    }

    private var item: UpdatePlanItem {
        UpdatePlanItem(id: UUID(), driveID: UUID(), driveName: "VENTOY", entryID: "windows-11",
                       channelID: "default", title: "Windows 11", fromVersion: "25H2",
                       toVersion: "25H2 v2", fileName: "", sizeBytes: nil, isVerifiable: false,
                       replacesFileName: nil, needsManualDownload: true,
                       release: Release(version: .parse("25H2")!, fileName: "", mediaRevision: 2),
                       installedFileName: "Win11_25H2_English_x64.iso",
                       driveKeepsOldVersions: false, keepReplacedAsPinned: false)
    }

    func testARefusalIsReportedInMicrosoftsOwnWords() async {
        // "How do I know if it is working?" — this is the answer: the refusal
        // is carried out of the resolver verbatim rather than swallowed.
        let resolver = FakeWindowsResolver(result: .refused("Sentinel marked this request as rejected."))
        let store = await makeStore(autoDownload: true, resolver: resolver)
        let attempt = await store.attemptWindowsDownload(for: item)
        XCTAssertEqual(attempt, .refused("Sentinel marked this request as rejected."))
        XCTAssertNil(attempt.download)
        XCTAssertEqual(resolver.calls, 1)
        // The hand-off page is still there, which is what the sheet falls back to.
        XCTAssertNotNil(store.manualDownloadPage(entryID: "windows-11", channelID: "default"))
    }

    func testTheTestButtonCanAskWithoutADriveOrAnAssignment() async {
        let resolver = FakeWindowsResolver(result: .refused("Sentinel marked this request as rejected."))
        let store = await makeStore(autoDownload: false, resolver: resolver)
        // Settings tests the mechanism, so it finds the channel itself — and it
        // works with the setting off, because that is what "does this work?"
        // means before you decide to turn it on.
        let channel = store.firstWindowsChannel
        XCTAssertEqual(channel?.entryID, "windows-11")
        let attempt = await store.attemptWindowsDownload(entryID: "windows-11", channelID: "default")
        XCTAssertEqual(attempt, .refused("Sentinel marked this request as rejected."))
        XCTAssertEqual(resolver.calls, 1)
    }

    func testASuccessfulResolveCarriesTheChecksumIntoTheRequest() async throws {
        let digest = String(repeating: "a", count: 64)
        let resolver = FakeWindowsResolver(resolved: .init(
            url: URL(string: "https://ms.invalid/Win11_25H2_English_x64v2.iso")!,
            fileName: "Win11_25H2_English_x64v2.iso", sha256: digest))
        let store = await makeStore(autoDownload: true, resolver: resolver)
        let attempt = await store.attemptWindowsDownload(for: item)
        let resolved = try XCTUnwrap(attempt.download)
        XCTAssertEqual(resolved.sha256, digest)
        XCTAssertEqual(resolver.lastCatalog?.productEditionID, "3321")

        // The release handed to the pipeline is a normal, verifiable one — the
        // point of insisting on the checksum that comes with the link.
        var release = item.release
        release.isoURL = resolved.url
        release.fileName = resolved.fileName
        release.sha256 = resolved.sha256
        XCTAssertTrue(release.isVerifiable)
        XCTAssertEqual(DownloadArtifact.placedFileName(for: release), "Win11_25H2_English_x64v2.iso")
    }

    func testAnEntryWithNoConnectorConfigurationIsNeverAttempted() async {
        let resolver = FakeWindowsResolver(result: .refused("unused"))
        let settings = settings()
        settings.attemptWindowsAutoDownload = true
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil,
                             settings: settings)
        store.windowsResolver = resolver
        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows,
            channels: [Channel(id: "default", name: "Current release", provider: .windowsManual(
                infoURL: URL(string: "https://microsoft.invalid/w11")!,
                downloadPage: URL(string: "https://microsoft.invalid/w11")!))],
            isBuiltIn: false))

        let attempt = await store.attemptWindowsDownload(for: item)
        // Says so, rather than failing silently the way a bare nil did.
        guard case .failed(let reason) = attempt else { return XCTFail("expected .failed, got \(attempt)") }
        XCTAssertTrue(reason.contains("no Microsoft download configuration"), reason)
        XCTAssertEqual(resolver.calls, 0)
        XCTAssertNil(store.firstWindowsChannel)
    }

    // MARK: - Reading the refusal

    func testMicrosoftsOwnMessageIsWhatGetsShown() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"Errors":[{"Key":"ErrorSettings.SentinelReject",
                    "Value":"Sentinel marked this request as rejected.","Type":8}]}
        """.utf8))
        XCTAssertEqual(WindowsDownloadResolver.refusal(in: json),
                       "Sentinel marked this request as rejected.")
    }

    func testARefusalWithNoMessageStillSaysSomething() throws {
        let json = try JSONSerialization.jsonObject(with: Data("{\"Errors\":null}".utf8))
        XCTAssertEqual(WindowsDownloadResolver.refusal(in: json),
                       "Microsoft answered without a download link.")
    }
}

private final class FakeWindowsResolver: WindowsDownloadResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let result: WindowsDownloadAttempt
    private var _calls = 0
    private var _lastCatalog: WindowsMediaCatalog?

    init(result: WindowsDownloadAttempt) { self.result = result }

    convenience init(resolved: WindowsResolvedDownload) { self.init(result: .resolved(resolved)) }

    var calls: Int { lock.withLock { _calls } }
    var lastCatalog: WindowsMediaCatalog? { lock.withLock { _lastCatalog } }

    func attempt(catalog: WindowsMediaCatalog, referer: URL) async -> WindowsDownloadAttempt {
        lock.withLock {
            _calls += 1
            _lastCatalog = catalog
        }
        return result
    }
}
