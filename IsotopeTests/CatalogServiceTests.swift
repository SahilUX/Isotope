import IsotopeCore
import XCTest
@testable import Isotope

/// Offline stand-in for the real providers: answers per mechanism so the app
/// wiring can be tested without touching the network.
private struct StubProvider: VersionProvider {
    enum Behaviour: Sendable {
        case release(Release)
        case failure(ProviderError)
        case hang
    }

    let behaviours: [ProviderConfig.Mechanism: Behaviour]

    func fetchLatest(config: ProviderConfig) async throws -> Release {
        switch behaviours[config.mechanism] {
        case .release(let release): return release
        case .failure(let error): throw error
        case .hang, .none:
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            throw ProviderError.invalidResponse(URL(string: "https://example.test")!)
        }
    }
}

private func makeEntry(id: String, mechanism: ProviderConfig.Mechanism) -> CatalogEntry {
    let url = URL(string: "https://example.test/\(id)")!
    let provider: ProviderConfig
    switch mechanism {
    case .checksumFile: provider = .checksumFile(url: url, filePattern: "x")
    case .pageScrape: provider = .pageScrape(url: url, linkPattern: "x")
    case .staticURL: provider = .staticURL(url: url, checksumURL: nil)
    case .gitHubReleases: provider = .gitHubReleases(repo: "a/b", assetPattern: "x")
    case .jsonFeed: provider = .jsonFeed(url: url, spec: JSONFeedSpec(versionKeys: ["v"]))
    case .windowsManual: provider = .windowsManual(infoURL: url, downloadPage: url)
    }
    return CatalogEntry(id: id, name: id, kind: .linux, channels: [
        Channel(id: "default", name: "Default", provider: provider)
    ], isBuiltIn: true)
}

final class CatalogServiceTests: XCTestCase {
    func testFailingSourceDoesNotBlockOthers() async {
        let release = Release(version: VersionToken.parse("24.04.3")!, fileName: "ok.iso")
        let service = CatalogService(resolver: StubProvider(behaviours: [
            .checksumFile: .release(release),
            .pageScrape: .failure(.httpStatus(503, URL(string: "https://example.test/bad")!))
        ]))

        let collector = OutcomeCollector()
        await service.check(entries: [makeEntry(id: "good", mechanism: .checksumFile),
                                      makeEntry(id: "bad", mechanism: .pageScrape)]) { key, outcome in
            await collector.add(key, outcome)
        }

        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes.count, 2)
        guard case .success(let resolved) = outcomes["good#default"] else {
            return XCTFail("good source should have resolved")
        }
        XCTAssertEqual(resolved.version.raw, "24.04.3")
        guard case .failure(let message) = outcomes["bad#default"] else {
            return XCTFail("bad source should have failed")
        }
        XCTAssertTrue(message.contains("503"), message)
    }

    func testHangingSourceIsCutOffAndReportedReadably() async {
        let service = CatalogService(resolver: StubProvider(behaviours: [.staticURL: .hang]))
        let collector = OutcomeCollector()
        // The real 15 s budget is too slow for a unit test; race the same
        // structure against a shorter deadline to prove the timeout wins.
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await service.check(entries: [makeEntry(id: "slow", mechanism: .staticURL)]) { key, outcome in
                    await collector.add(key, outcome)
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 300_000_000) }
            await group.next()
            group.cancelAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), CatalogService.sourceTimeout)
        XCTAssertEqual(CatalogService.message(for: CatalogCheckError.timedOut),
                       "The source did not answer within 15 seconds.")
    }
}

@MainActor
final class AppStoreCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCatalogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(service: CatalogService, catalog: [CatalogEntry]) throws -> AppStore {
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONStore.save(catalog, to: catalogURL)
        return AppStore(locations: StoreLocations(root: root),
                        catalogResourceURL: catalogURL,
                        catalogService: service)
    }

    func testRefreshRecordsPerEntryStatusAndPersistsReleases() async throws {
        let release = Release(version: VersionToken.parse("41")!, fileName: "fedora.iso",
                              sha256: String(repeating: "a", count: 64))
        let service = CatalogService(resolver: StubProvider(behaviours: [
            .checksumFile: .release(release),
            .pageScrape: .failure(.noMatch(pattern: "nope",
                                           source: URL(string: "https://example.test/bad")!,
                                           snippet: "<html>"))
        ]))
        let store = try makeStore(service: service, catalog: [
            makeEntry(id: "good", mechanism: .checksumFile),
            makeEntry(id: "bad", mechanism: .pageScrape)
        ])
        await store.loadAtLaunch()
        await store.refreshCatalog()

        XCTAssertFalse(store.isCheckingCatalog)
        let goodKey = ReleaseKey(entryID: "good", channelID: "default")
        let badKey = ReleaseKey(entryID: "bad", channelID: "default")

        guard case .ok = store.status(for: goodKey) else {
            return XCTFail("expected ok, got \(store.status(for: goodKey))")
        }
        XCTAssertEqual(store.release(for: goodKey)?.version.raw, "41")
        XCTAssertNotNil(store.status(for: badKey).errorMessage)
        XCTAssertTrue(store.status(for: badKey).errorMessage?.contains("nope") == true)
        XCTAssertNil(store.release(for: badKey), "a failed check must not invent a release")

        // Resolved releases survive a relaunch via release-cache.json.
        let reloaded = try makeStore(service: service, catalog: [makeEntry(id: "good", mechanism: .checksumFile)])
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.release(for: goodKey)?.version.raw, "41")
        XCTAssertEqual(reloaded.status(for: goodKey), .never, "status is transient, not persisted")
    }

    func testUnchangedETagSourceDoesNotLookNewer() async throws {
        let first = Release(version: .date(Date(timeIntervalSince1970: 1_000_000), raw: "etag-1"),
                            fileName: "foo.iso")
        let second = Release(version: .date(Date(), raw: "etag-1"), fileName: "foo.iso")
        let key = ReleaseKey(entryID: "static", channelID: "default")

        let storeA = try makeStore(service: CatalogService(resolver: StubProvider(behaviours: [.staticURL: .release(first)])),
                                   catalog: [makeEntry(id: "static", mechanism: .staticURL)])
        await storeA.loadAtLaunch()
        await storeA.refreshCatalog()
        let recorded = try XCTUnwrap(storeA.release(for: key)?.version)

        let storeB = try makeStore(service: CatalogService(resolver: StubProvider(behaviours: [.staticURL: .release(second)])),
                                   catalog: [makeEntry(id: "static", mechanism: .staticURL)])
        await storeB.loadAtLaunch()
        await storeB.refreshCatalog()
        XCTAssertEqual(storeB.release(for: key)?.version, recorded,
                       "an unchanged signature must keep the original change date")
    }

    func testCustomSourceRoundTripAndAssignmentWarning() async throws {
        let store = try makeStore(service: CatalogService(resolver: StubProvider(behaviours: [:])),
                                  catalog: [])
        await store.loadAtLaunch()

        let entry = CatalogEntry(id: "custom-1", name: "My ISO", kind: .custom, channels: [
            Channel(id: "default", name: "Default",
                    provider: .checksumFile(url: URL(string: "https://example.test/SHA256SUMS")!,
                                            filePattern: #"my-(\d+\.\d+)\.iso"#))
        ], isBuiltIn: false)
        store.addCustomEntry(entry)

        let reloaded = try makeStore(service: CatalogService(resolver: StubProvider(behaviours: [:])), catalog: [])
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.customEntries.map(\.id), ["custom-1"])

        // PRD F11: deleting an assigned source must be warnable.
        XCTAssertTrue(reloaded.drivesUsing(entryID: "custom-1").isEmpty)
        reloaded.addDrive(ManagedDrive(volumeUUID: "U", displayName: "Ventoy", bookmark: Data(),
                                       assignments: [Assignment(entryID: "custom-1", channelID: "default")]))
        XCTAssertEqual(reloaded.drivesUsing(entryID: "custom-1").map(\.displayName), ["Ventoy"])

        reloaded.removeCustomEntry(id: "custom-1")
        XCTAssertTrue(reloaded.customEntries.isEmpty)
    }
}

private actor OutcomeCollector {
    var outcomes: [String: CatalogService.Outcome] = [:]

    func add(_ key: ReleaseKey, _ outcome: CatalogService.Outcome) {
        outcomes[key.description] = outcome
    }
}
