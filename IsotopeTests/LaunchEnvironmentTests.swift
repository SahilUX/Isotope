import IsotopeCore
import XCTest
@testable import Isotope

/// The hosted test run must never reach the user's own state folder, the
/// network or the drive monitor. These tests drive the decision with a fake
/// environment; they never read or write the real folders, only compare paths.
final class LaunchEnvironmentTests: XCTestCase {
    private let fakeTemp = URL(fileURLWithPath: "/tmp/isotope-launch-fake", isDirectory: true)

    private func testRun(_ variable: String = "XCTestConfigurationFilePath") -> LaunchEnvironment {
        LaunchEnvironment(environment: [variable: "/some/path.xctestconfiguration"],
                          temporaryDirectory: fakeTemp)
    }

    private func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = folder.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    func testTestRunUsesTemporaryLocationsOutsideTheRealFolders() {
        for variable in LaunchEnvironment.testVariables {
            let launch = testRun(variable)
            XCTAssertTrue(launch.isTestRun, variable)
            XCTAssertTrue(isInside(launch.storeLocations.root, fakeTemp))
            XCTAssertTrue(isInside(launch.cacheLocations.root, fakeTemp))
            XCTAssertFalse(isInside(launch.storeLocations.root, StoreLocations.applicationSupport().root))
            XCTAssertFalse(isInside(launch.cacheLocations.root, CacheLocations.userCaches().root))
            XCTAssertNotEqual(launch.storeLocations.root, launch.cacheLocations.root)
        }
    }

    func testTestRunLocationsAreUniquePerCall() {
        let first = testRun()
        let second = testRun()
        XCTAssertNotEqual(first.storeLocations.root, second.storeLocations.root)
        XCTAssertNotEqual(first.cacheLocations.root, second.cacheLocations.root)
    }

    func testTestRunSkipsEverythingThatReachesOutside() {
        let launch = testRun()
        XCTAssertFalse(launch.startsDriveMonitor)
        XCTAssertFalse(launch.startsPeriodicRefresh)
        XCTAssertFalse(launch.refreshesCatalogAtLaunch)
        XCTAssertFalse(launch.routesNotifications)
    }

    func testEmptyEnvironmentIsProduction() {
        let launch = LaunchEnvironment(environment: [:], temporaryDirectory: fakeTemp)
        XCTAssertFalse(launch.isTestRun)
        XCTAssertEqual(launch.storeLocations.root, StoreLocations.applicationSupport().root)
        XCTAssertEqual(launch.cacheLocations.root, CacheLocations.userCaches().root)
        XCTAssertTrue(launch.startsDriveMonitor)
        XCTAssertTrue(launch.startsPeriodicRefresh)
        XCTAssertTrue(launch.refreshesCatalogAtLaunch)
        XCTAssertTrue(launch.routesNotifications)
    }

    func testUnrelatedOrEmptyVariablesDoNotCountAsATestRun() {
        let launch = LaunchEnvironment(
            environment: ["XCTestConfigurationFilePath": "", "HOME": "/Users/someone"],
            temporaryDirectory: fakeTemp)
        XCTAssertFalse(launch.isTestRun)
        XCTAssertEqual(launch.storeLocations.root, StoreLocations.applicationSupport().root)
    }
}
