import IsotopeCore
import Observation
import XCTest
@testable import Isotope

/// Every switch in Settings writes through a `Binding` onto `AppSettings`, and
/// SwiftUI only redraws what it was told changed. As a struct behind
/// `UserDefaults`, nothing here was observable: a toggle wrote the new value and
/// then carried on drawing the old one, so the whole panel looked inert while
/// working perfectly.
///
/// These tests are the guard on that — they assert the observation itself, not
/// the storage, because storage was never the part that broke.
final class AppSettingsObservationTests: XCTestCase {
    private var defaultsName: String!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        defaultsName = "IsotopeSettingsObservation-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    /// Fires `onChange` exactly the way SwiftUI's redraw does.
    private func expectChange(_ description: String,
                              reading: @escaping () -> Void,
                              mutating: () -> Void) {
        let changed = expectation(description: description)
        withObservationTracking(reading) { changed.fulfill() }
        mutating()
        wait(for: [changed], timeout: 1)
    }

    func testTogglingTheWindowsAttemptIsObserved() {
        expectChange("attemptWindowsAutoDownload") { [settings] in
            _ = settings!.attemptWindowsAutoDownload
        } mutating: {
            settings.attemptWindowsAutoDownload = true
        }
        XCTAssertTrue(settings.attemptWindowsAutoDownload)
    }

    func testTogglingCacheDiscardIsObserved() {
        expectChange("discardAfterPlacement") { [settings] in
            _ = settings!.discardAfterPlacement
        } mutating: {
            settings.discardAfterPlacement = false
        }
        XCTAssertFalse(settings.discardAfterPlacement)
    }

    func testTogglingFlashVerificationIsObserved() {
        expectChange("flashVerification") { [settings] in
            _ = settings!.flashVerification
        } mutating: {
            settings.flashVerification = false
        }
    }

    func testTogglingNotificationsIsObserved() {
        expectChange("notificationsEnabled") { [settings] in
            _ = settings!.notificationsEnabled
        } mutating: {
            settings.notificationsEnabled = false
        }
    }

    func testTogglingAutoResumeIsObserved() {
        expectChange("autoResumeDownloads") { [settings] in
            _ = settings!.autoResumeDownloads
        } mutating: {
            settings.autoResumeDownloads = true
        }
    }

    func testThePickersAreObservedToo() {
        // Concurrency, cache limit and interval are Pickers, which have exactly
        // the same problem when their source is invisible to observation.
        expectChange("maxConcurrentDownloads") { [settings] in
            _ = settings!.maxConcurrentDownloads
        } mutating: {
            settings.maxConcurrentDownloads = 4
        }
        expectChange("cacheCapacityBytes") { [settings] in
            _ = settings!.cacheCapacityBytes
        } mutating: {
            settings.cacheCapacityBytes = 5 << 30
        }
        expectChange("refreshInterval") { [settings] in
            _ = settings!.refreshInterval
        } mutating: {
            settings.refreshInterval = 3600
        }
    }

    func testValuesStillPersistAndClamp() {
        settings.maxConcurrentDownloads = 99
        settings.cacheCapacityBytes = -1
        settings.refreshInterval = 5
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
        XCTAssertEqual(reloaded.maxConcurrentDownloads, 8)
        XCTAssertEqual(reloaded.cacheCapacityBytes, 0)
        XCTAssertEqual(reloaded.refreshInterval, 15 * 60)
    }

    func testTheStoreAndItsViewsShareOneSettingsObject() async {
        // A struct copy would have made the store's view of a setting diverge
        // from the panel's the moment either wrote to it.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeSettingsShared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = await AppStore(locations: StoreLocations(root: root),
                                   catalogResourceURL: nil, settings: settings)
        settings.discardAfterPlacement = false
        let seen = await store.discardsCacheAfterPlacement
        XCTAssertFalse(seen)
    }
}
