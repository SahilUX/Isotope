import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F40 — flashed-USB auto-detect, entirely offline: the "sticks" are
/// `FlashDevice` values carrying the volume labels DiskArbitration would report.
@MainActor
final class FlashedContentsDetectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeContentsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func entry(id: String, name: String, organization: String, label: String?,
                       channels: [Channel]) -> CatalogEntry {
        CatalogEntry(id: id, name: name, kind: .linux, organization: organization,
                     channels: channels, isBuiltIn: false, volumeLabelPattern: label)
    }

    private func channel(_ id: String, _ name: String, label: String? = nil) -> Channel {
        Channel(id: id, name: name,
                provider: .staticURL(url: URL(string: "https://example.invalid/\(id).iso")!,
                                     checksumURL: nil),
                volumeLabelPattern: label)
    }

    private func makeStore() async -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        await store.loadAtLaunch()
        store.notifications = RecordingNotificationService()
        store.addCustomEntry(entry(id: "ubuntu-desktop", name: "Ubuntu Desktop",
                                   organization: "Ubuntu",
                                   label: "^Ubuntu (\\d+\\.\\d+(?:\\.\\d+)?)(?: LTS)? amd64",
                                   channels: [channel("lts", "LTS"), channel("latest", "Latest")]))
        store.addCustomEntry(entry(id: "debian", name: "Debian", organization: "Debian",
                                   label: "^Debian (\\d+\\.\\d+\\.\\d+) amd64",
                                   channels: [
                                    channel("netinst", "netinst",
                                            label: "^Debian (\\d+\\.\\d+\\.\\d+) amd64 n"),
                                    channel("dvd", "DVD",
                                            label: "^Debian (\\d+\\.\\d+\\.\\d+) amd64 1"),
                                   ]))
        // No label pattern: nothing may ever be concluded about this one.
        store.addCustomEntry(entry(id: "memtest", name: "Memtest86+",
                                   organization: "Tools & rescue", label: nil,
                                   channels: [channel("default", "Stable")]))
        return store
    }

    private func device(labels: [String], bsdName: String = "disk4",
                        serial: String? = "SERIAL-1") -> FlashDevice {
        FlashDevice(bsdName: bsdName, displayName: "SanDisk Cruzer Blade", sizeBytes: 32 << 30,
                    isWholeDisk: true, isExternal: true, isRemovableOrEjectable: true, isUSB: true,
                    isBootDisk: false,
                    hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: serial),
                    volumeNames: labels, volumeUUIDs: ["VOL-1"])
    }

    // MARK: - Registration-time detection

    func testDetectedContentsSummaryNamesEntryChannelAndVersion() async throws {
        let store = await makeStore()
        XCTAssertEqual(store.detectedContentsSummary(for: device(labels: ["Ubuntu 24.04.4 LTS amd64"])),
                       "Ubuntu Desktop 24.04.4")
        XCTAssertEqual(store.detectedContentsSummary(for: device(labels: ["Debian 13.6.0 amd64 n"])),
                       "Debian (netinst) 13.6.0")
        XCTAssertNil(store.detectedContentsSummary(for: device(labels: ["UNTITLED"])))
        XCTAssertNil(store.detectedContentsSummary(for: device(labels: [])))
    }

    func testRegistrationRecordsTheDetectedVersionAsInstalled() async throws {
        let store = await makeStore()
        let stick = device(labels: ["Ubuntu 24.04.4 LTS amd64"])
        let detected = try XCTUnwrap(store.detectedContents(for: stick))
        let drive = try store.registerFlashedDrive(device: stick, entryID: "ubuntu-desktop",
                                                   channelID: "lts", detected: detected)
        let installed = try XCTUnwrap(drive.assignments.first?.installed)
        XCTAssertEqual(installed.version, VersionToken.parse("24.04.4"))
        XCTAssertEqual(installed.fileName, "Ubuntu 24.04.4 LTS amd64")
        // Isotope recognised it; it did not write it (PRD F7/F22 semantics).
        XCTAssertFalse(installed.placedByApp)
    }

    func testADetectionForADifferentEntryIsNotRecorded() async throws {
        let store = await makeStore()
        let stick = device(labels: ["Ubuntu 24.04.4 LTS amd64"])
        let detected = try XCTUnwrap(store.detectedContents(for: stick))
        // The user overrode the preselection and picked Debian instead.
        let drive = try store.registerFlashedDrive(device: stick, entryID: "debian",
                                                   channelID: "netinst", detected: detected)
        XCTAssertNil(drive.assignments.first?.installed)
    }

    // MARK: - Attach-time re-check

    func testANewerVersionOnTheStickUpdatesInstalledAndLogsIt() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(
            device: device(labels: ["Ubuntu 24.04.4 LTS amd64"]), entryID: "ubuntu-desktop",
            channelID: "lts", detected: store.detectedContents(for: device(labels: ["Ubuntu 24.04.4 LTS amd64"])))

        let outcome = store.reconcileFlashedContents(driveID: drive.id,
                                                     labels: ["Ubuntu 26.04 amd64"])
        XCTAssertEqual(outcome, .versionUpdated(VersionToken.parse("26.04")!))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.version,
                       VersionToken.parse("26.04"))
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.driveID, drive.id)
        XCTAssertNil(store.driveIssues[drive.id])
    }

    func testTheSameVersionChangesNothing() async throws {
        let store = await makeStore()
        let stick = device(labels: ["Ubuntu 24.04.4 LTS amd64"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "ubuntu-desktop",
                                                   channelID: "lts",
                                                   detected: store.detectedContents(for: stick))
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id,
                                                      labels: ["Ubuntu 24.04.4 LTS amd64"]),
                       .unchanged)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testALabelThatNoLongerMatchesFlagsContentsChanged() async throws {
        let store = await makeStore()
        let stick = device(labels: ["Ubuntu 24.04.4 LTS amd64"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "ubuntu-desktop",
                                                   channelID: "lts",
                                                   detected: store.detectedContents(for: stick))

        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id,
                                                      labels: ["Debian 13.6.0 amd64 n"]),
                       .contentsChanged)
        XCTAssertEqual(store.driveIssues[drive.id],
                       .contentsChanged(label: "Debian 13.6.0 amd64 n", expected: "Ubuntu Desktop"))
        XCTAssertEqual(store.status(of: drive), .needsAttention)
        // The recorded install is left alone: the flag is a warning, not a guess.
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.version,
                       VersionToken.parse("24.04.4"))

        // Re-flashing it back to a matching image retracts the warning.
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id,
                                                      labels: ["Ubuntu 26.04 amd64"]),
                       .versionUpdated(VersionToken.parse("26.04")!))
        XCTAssertNil(store.driveIssues[drive.id])
    }

    func testSilenceIsNotEvidence() async throws {
        let store = await makeStore()
        let stick = device(labels: ["Ubuntu 24.04.4 LTS amd64"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "ubuntu-desktop",
                                                   channelID: "lts",
                                                   detected: store.detectedContents(for: stick))
        // A freshly flashed Linux image often exposes nothing macOS mounts.
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id, labels: []), .noEvidence)
        XCTAssertNil(store.driveIssues[drive.id])

        // An entry with no pattern can never be contradicted either.
        let other = try store.registerFlashedDrive(device: device(labels: ["MT86PLUS"],
                                                                  bsdName: "disk7",
                                                                  serial: "SERIAL-2"),
                                                   entryID: "memtest", channelID: "default")
        XCTAssertEqual(store.reconcileFlashedContents(driveID: other.id, labels: ["ANYTHING"]),
                       .noEvidence)
        XCTAssertNil(store.driveIssues[other.id])
    }
}
