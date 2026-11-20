import Foundation
import IsotopeCore

/// What kind of process this is, decided once at launch from its environment.
///
/// `IsotopeTests` is a hosted bundle: `xcodebuild test` starts the real app and
/// loads the tests into it. Left alone, that app reads and writes the user's own
/// state folder, goes online and starts watching volumes. Under XCTest the app
/// therefore gets a throwaway state and cache folder, and skips everything that
/// reaches outside the process: the drive monitor, the periodic and launch
/// catalog refresh, and the notification centre.
///
/// A plain value over an environment dictionary so a test can drive it with a
/// fake environment. Without an XCTest variable it resolves to the production
/// locations and the full launch sequence.
struct LaunchEnvironment {
    /// Set by the test runner in every process it hosts tests in.
    static let testVariables = ["XCTestConfigurationFilePath", "XCTestBundlePath"]

    let isTestRun: Bool
    let storeLocations: StoreLocations
    let cacheLocations: CacheLocations

    init(environment: [String: String],
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         productionStore: () -> StoreLocations = { .applicationSupport() },
         productionCache: () -> CacheLocations = { .userCaches() }) {
        let isTestRun = Self.testVariables.contains { !(environment[$0] ?? "").isEmpty }
        self.isTestRun = isTestRun
        if isTestRun {
            // A fresh folder per launch: tests never see each other's state.
            let root = temporaryDirectory
                .appendingPathComponent("IsotopeTestRun-\(UUID().uuidString)", isDirectory: true)
            storeLocations = StoreLocations(root: root.appendingPathComponent("State", isDirectory: true))
            cacheLocations = CacheLocations(root: root.appendingPathComponent("Caches", isDirectory: true))
        } else {
            storeLocations = productionStore()
            cacheLocations = productionCache()
        }
    }

    /// The running process.
    static var current: LaunchEnvironment {
        LaunchEnvironment(environment: ProcessInfo.processInfo.environment)
    }

    var startsDriveMonitor: Bool { !isTestRun }
    var startsPeriodicRefresh: Bool { !isTestRun }
    var refreshesCatalogAtLaunch: Bool { !isTestRun }
    var routesNotifications: Bool { !isTestRun }
}
