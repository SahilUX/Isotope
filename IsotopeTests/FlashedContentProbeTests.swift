import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F44 — the flashed-drive content probe, app side. The "mounted volume" is
/// a temporary directory this test creates and deletes; no device is touched, and
/// the read path is asserted to leave it byte-for-byte unchanged.
@MainActor
final class FlashedContentProbeTests: XCTestCase {
    private var root: URL!
    private var volume: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeProbeTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("FakeVolume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// Exactly what `proxmox-ve_9.2-1.iso` carries at `.disk/info`.
    private let proxmoxInfo = """
    RELEASE='9.2'
    ISORELEASE='1'
    ISONAME='proxmox-ve'
    PRODUCT='pve'
    PRODUCTLONG='Proxmox VE'

    """

    private let proxmoxProbes = [ContentProbe(
        path: ".disk/info",
        pattern: #"^RELEASE='(\d+\.\d+)'[\r\n]+ISORELEASE='(\d+)'"#,
        versionTemplate: "$1-$2")]

    private func write(_ text: String, to relativePath: String) throws {
        let url = volume.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, name: name,
                provider: .staticURL(url: URL(string: "https://example.invalid/\(id).iso")!,
                                     checksumURL: nil))
    }

    private func makeStore() async -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        await store.loadAtLaunch()
        store.notifications = RecordingNotificationService()
        // Proxmox VE: the user's actual case. Its label is "PVE" and carries no
        // version at all, which is exactly why the probe exists.
        store.addCustomEntry(CatalogEntry(id: "proxmox-ve", name: "Proxmox VE", kind: .linux,
                                          organization: "Proxmox",
                                          channels: [channel("default", "Stable")],
                                          isBuiltIn: false, volumeLabelPattern: "^PVE$",
                                          contentProbes: proxmoxProbes))
        // No label pattern at all, but a probe: the probe alone must be enough.
        store.addCustomEntry(CatalogEntry(id: "probe-only", name: "Probe Only", kind: .linux,
                                          organization: "Test",
                                          channels: [channel("default", "Stable")],
                                          isBuiltIn: false, volumeLabelPattern: nil,
                                          contentProbes: [ContentProbe(path: ".disk/info",
                                                                       pattern: #"^Thing (\d+\.\d+)"#)]))
        // A label pattern and no probes: F40 behaviour must be untouched.
        store.addCustomEntry(CatalogEntry(id: "labelled", name: "Labelled", kind: .linux,
                                          organization: "Test",
                                          channels: [channel("default", "Stable")],
                                          isBuiltIn: false,
                                          volumeLabelPattern: #"^Labelled (\d+\.\d+) amd64"#))
        return store
    }

    private func device(labels: [String], mountPoints: [URL]? = nil,
                        bsdName: String = "disk4", serial: String = "SERIAL-1") -> FlashDevice {
        FlashDevice(bsdName: bsdName, displayName: "Kingston DataTraveler", sizeBytes: 32 << 30,
                    isWholeDisk: true, isExternal: true, isRemovableOrEjectable: true, isUSB: true,
                    isBootDisk: false,
                    hardwareID: HardwareID(vendorID: 0x0951, productID: 0x1666, serialNumber: serial),
                    volumeNames: labels, volumeUUIDs: ["VOL-1"],
                    volumeMountPoints: mountPoints ?? [volume])
    }

    // MARK: - Reading

    func testReadsTheMarkerFileOffAMountedVolume() throws {
        try write(proxmoxInfo, to: ".disk/info")
        XCTAssertEqual(VolumeContentProbe.version(probes: proxmoxProbes, volumes: [volume])?.raw,
                       "9.2-1")
    }

    func testAMissingFileOrVolumeIsSilent() throws {
        XCTAssertNil(VolumeContentProbe.version(probes: proxmoxProbes, volumes: [volume]))
        XCTAssertNil(VolumeContentProbe.version(probes: proxmoxProbes,
                                                volumes: [root.appendingPathComponent("gone")]))
        XCTAssertNil(VolumeContentProbe.version(probes: [], volumes: [volume]))
    }

    func testSeveralVolumesAreTriedInOrder() throws {
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(proxmoxInfo.utf8).write(to: {
            let url = second.appendingPathComponent(".disk/info")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return url
        }())
        // The first volume (an EFI partition, say) holds nothing readable.
        XCTAssertEqual(VolumeContentProbe.version(probes: proxmoxProbes,
                                                  volumes: [volume, second])?.raw, "9.2-1")
    }

    /// A catalog typo naming something enormous must cost kilobytes, not the file.
    func testReadIsCappedAtSixtyFourKilobytes() throws {
        XCTAssertEqual(VolumeContentProbe.maxReadBytes, 64 * 1024)
        let padding = String(repeating: "x", count: VolumeContentProbe.maxReadBytes)
        try write(padding + "\nRELEASE='9.2'\nISORELEASE='1'\n", to: ".disk/info")
        // The version sits past the cap, so nothing is found — and nothing beyond
        // the cap was ever read.
        XCTAssertNil(VolumeContentProbe.version(probes: [ContentProbe(
            path: ".disk/info", pattern: #"RELEASE='(\d+\.\d+)'"#)], volumes: [volume]))
        let text = try XCTUnwrap(VolumeContentProbe.readText(at: volume.appendingPathComponent(".disk/info")))
        XCTAssertEqual(text.utf8.count, VolumeContentProbe.maxReadBytes)
    }

    /// The read path must not create, modify or delete anything on the volume.
    func testProbingLeavesTheVolumeUntouched() throws {
        try write(proxmoxInfo, to: ".disk/info")
        let file = volume.appendingPathComponent(".disk/info")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let listingBefore = try FileManager.default.subpathsOfDirectory(atPath: volume.path).sorted()

        _ = VolumeContentProbe.version(probes: proxmoxProbes, volumes: [volume])

        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(after[.size] as? Int, before[.size] as? Int)
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: volume.path).sorted(),
                       listingBefore)
        XCTAssertEqual(try Data(contentsOf: file), Data(proxmoxInfo.utf8))
    }

    // MARK: - Store integration

    /// The Kingston case: label "PVE" says *which* image, the probe says which
    /// version, and the row stops reading "Unknown".
    func testProbeSuppliesTheVersionALabelCannot() async throws {
        let store = await makeStore()
        try write(proxmoxInfo, to: ".disk/info")
        let stick = device(labels: ["PVE"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "proxmox-ve",
                                                   channelID: "default",
                                                   detected: store.detectedContents(for: stick))
        // Registration recorded the image but no version — the label has none.
        XCTAssertNil(drive.assignments.first?.installed?.version)

        let probed = store.probedVersion(for: drive, device: stick)
        XCTAssertEqual(probed, VersionToken.parse("9.2-1"))

        let outcome = store.reconcileFlashedContents(driveID: drive.id, labels: stick.volumeNames,
                                                     probedVersion: probed)
        XCTAssertEqual(outcome, .versionUpdated(VersionToken.parse("9.2-1")!))
        let installed = try XCTUnwrap(store.drive(id: drive.id)?.assignments.first?.installed)
        XCTAssertEqual(installed.version, VersionToken.parse("9.2-1"))
        XCTAssertFalse(installed.placedByApp, "Isotope read it; it did not write it")
        XCTAssertNil(store.driveIssues[drive.id])
        // History records where the version came from.
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.version, VersionToken.parse("9.2-1"))
    }

    func testProbeWinsOverALabelThatDoesCarryAVersion() async throws {
        let store = await makeStore()
        store.addCustomEntry(CatalogEntry(id: "both", name: "Both", kind: .linux,
                                          organization: "Test",
                                          channels: [channel("default", "Stable")],
                                          isBuiltIn: false,
                                          volumeLabelPattern: #"^Both (\d+\.\d+) amd64"#,
                                          contentProbes: [ContentProbe(path: ".disk/info",
                                                                       pattern: #"^Both (\d+\.\d+\.\d+)"#)]))
        try write("Both 1.2.3 - Release amd64", to: ".disk/info")
        let stick = device(labels: ["Both 1.2 amd64"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "both",
                                                   channelID: "default")
        let probed = store.probedVersion(for: drive, device: stick)
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id, labels: stick.volumeNames,
                                                      probedVersion: probed),
                       .versionUpdated(VersionToken.parse("1.2.3")!))
    }

    func testAnEntryWithNoLabelPatternIsStillAnsweredByItsProbe() async throws {
        let store = await makeStore()
        try write("Thing 3.1 - Release", to: ".disk/info")
        let stick = device(labels: [])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "probe-only",
                                                   channelID: "default")
        let probed = store.probedVersion(for: drive, device: stick)
        XCTAssertEqual(probed, VersionToken.parse("3.1"))
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id, labels: [],
                                                      probedVersion: probed),
                       .versionUpdated(VersionToken.parse("3.1")!))
        XCTAssertNil(store.driveIssues[drive.id])
    }

    /// F40 is intact: a label that no longer matches still flags "contents
    /// changed", and a probe reading of the *old* image does not paper over it.
    func testContentsChangedStillWinsOverAProbe() async throws {
        let store = await makeStore()
        try write(proxmoxInfo, to: ".disk/info")
        let stick = device(labels: ["PVE"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "proxmox-ve",
                                                   channelID: "default")
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id,
                                                      labels: ["SOMETHING ELSE"],
                                                      probedVersion: VersionToken.parse("9.2-1")),
                       .contentsChanged)
        XCTAssertEqual(store.driveIssues[drive.id],
                       .contentsChanged(label: "SOMETHING ELSE", expected: "Proxmox VE"))
        XCTAssertNil(store.drive(id: drive.id)?.assignments.first?.installed?.version)
    }

    /// No probes, no labels, nothing readable: the recorded version stands.
    func testNoEvidenceLeavesTheRecordedVersionAlone() async throws {
        let store = await makeStore()
        let stick = device(labels: [])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "labelled",
                                                   channelID: "default")
        XCTAssertNil(store.probedVersion(for: drive, device: stick))
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id, labels: [],
                                                      probedVersion: nil), .noEvidence)
        XCTAssertNil(store.driveIssues[drive.id])
    }

    /// A probe reporting the version already recorded changes nothing and writes
    /// no history — the drive is simply still what it was.
    func testAnUnchangedProbeReadingIsANoOp() async throws {
        let store = await makeStore()
        try write(proxmoxInfo, to: ".disk/info")
        let stick = device(labels: ["PVE"])
        let drive = try store.registerFlashedDrive(device: stick, entryID: "proxmox-ve",
                                                   channelID: "default")
        let probed = store.probedVersion(for: drive, device: stick)
        _ = store.reconcileFlashedContents(driveID: drive.id, labels: ["PVE"], probedVersion: probed)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.reconcileFlashedContents(driveID: drive.id, labels: ["PVE"],
                                                      probedVersion: probed), .unchanged)
        XCTAssertEqual(store.history.count, 1)
    }

    /// A Ventoy drive is never probed: F44 is a flashed-drive feature.
    func testVentoyDrivesAreNeverProbed() async throws {
        let store = await makeStore()
        let ventoy = ManagedDrive(volumeUUID: "V-1", displayName: "VENTOY", bookmark: Data(),
                                  assignments: [Assignment(entryID: "proxmox-ve",
                                                           channelID: "default")],
                                  kind: .ventoy)
        store.addDrive(ventoy)
        try write(proxmoxInfo, to: ".disk/info")
        XCTAssertNil(store.probedVersion(for: ventoy, device: device(labels: ["VENTOY"])))
    }
}
