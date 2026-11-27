import Foundation
import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F74, entirely with fakes: no disk is inspected, nothing is mounted.
final class VentoyVersionReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeVentoyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fakes

    private struct FakeDisks: VentoyDiskInspecting {
        var whole: String? = "disk9"
        var partition: VentoyEFIPartitionInfo?
        func wholeDisk(forVolumeAt url: URL) -> String? { whole }
        func partitionTwo(ofWholeDisk wholeDisk: String) -> VentoyEFIPartitionInfo? { partition }
    }

    private final class FakeMounter: PartitionMounting, @unchecked Sendable {
        private let lock = NSLock()
        var mountSucceeds = true
        /// A mount that "fails" but leaves something mounted (a timeout).
        var leavesMountedOnFailure = false
        /// Written into the mount directory when the mount succeeds.
        var config: String?
        private(set) var mounts: [(String, URL)] = []
        private(set) var unmounts: [URL] = []
        private var mounted: Set<URL> = []

        func mountReadOnly(devicePath: String, at directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            mounts.append((devicePath, directory))
            if mountSucceeds, let config {
                let grub = directory.appendingPathComponent("grub", isDirectory: true)
                try? FileManager.default.createDirectory(at: grub, withIntermediateDirectories: true)
                try? config.write(to: grub.appendingPathComponent("grub.cfg"), atomically: true, encoding: .utf8)
            }
            if mountSucceeds || leavesMountedOnFailure { mounted.insert(directory) }
            return mountSucceeds
        }

        func isMounted(at directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return mounted.contains(directory)
        }

        func unmount(directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            unmounts.append(directory)
            mounted.remove(directory)
            // Stand-in for the mounted filesystem going away.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("grub"))
            return true
        }
    }

    private func partition(whole: String = "disk9", partitionWhole: String = "disk9",
                           name: String = "disk9s2", size: Int64 = 32 * 1024 * 1024,
                           content: String = "0xEF", isUSB: Bool = true,
                           mountPoint: URL? = nil) -> VentoyEFIPartitionInfo {
        VentoyEFIPartitionInfo(
            candidate: VentoyEFIPartitionCandidate(
                dataWholeDisk: whole, partitionBSDName: name, partitionWholeDisk: partitionWhole,
                sizeBytes: size, content: content,
                disk: FlashDeviceDescription(bsdName: whole, displayName: "Stick",
                                             sizeBytes: 64_000_000_000, isUSB: isUSB)),
            mountPoint: mountPoint)
    }

    private func reader(disks: FakeDisks, mounter: FakeMounter) -> VentoyVersionReader {
        var reader = VentoyVersionReader(disks: disks, mounter: mounter)
        let base = root!
        reader.makeDirectory = {
            let url = base.appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return reader
    }

    private let grub = "function x {\n}\nset VENTOY_VERSION=\"1.1.18\"\n"
    private let volume = URL(fileURLWithPath: "/Volumes/Ventoy")

    // MARK: Eligibility

    func testWrongSizeIsNotMounted() {
        let mounter = FakeMounter()
        let result = reader(disks: FakeDisks(partition: partition(size: 300 * 1024 * 1024)), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testWrongTypeIsNotMounted() {
        let mounter = FakeMounter()
        let result = reader(disks: FakeDisks(partition: partition(content: "Windows_NTFS")), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testPartitionOnAnotherWholeDiskIsNotMounted() {
        let mounter = FakeMounter()
        let result = reader(disks: FakeDisks(partition: partition(partitionWhole: "disk3", name: "disk3s2")),
                            mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testNonUSBDiskIsNotMounted() {
        let mounter = FakeMounter()
        let result = reader(disks: FakeDisks(partition: partition(isUSB: false)), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testUnidentifiedDiskOrMissingPartitionIsUnknown() {
        let mounter = FakeMounter()
        XCTAssertNil(reader(disks: FakeDisks(whole: nil, partition: partition()), mounter: mounter)
            .readVersion(volumeURL: volume).version)
        XCTAssertNil(reader(disks: FakeDisks(partition: nil), mounter: mounter)
            .readVersion(volumeURL: volume).version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    // MARK: Mount, read, unmount

    func testReadsVersionAndUnmountsAndRemovesFolder() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        let result = reader(disks: FakeDisks(partition: partition()), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertEqual(result, .known(VentoyVersion("1.1.18")!))
        XCTAssertEqual(mounter.mounts.map(\.0), ["/dev/disk9s2"])
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(mounter.unmounts, [directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedMountIsUnknownAndLeavesNoFolder() throws {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        let result = reader(disks: FakeDisks(partition: partition()), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertTrue(mounter.unmounts.isEmpty, "nothing was mounted, so nothing to unmount")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedMountThatLeftAMountIsStillUnmounted() {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        mounter.leavesMountedOnFailure = true
        _ = reader(disks: FakeDisks(partition: partition()), mounter: mounter).readVersion(volumeURL: volume)
        XCTAssertEqual(mounter.unmounts.count, 1)
    }

    func testUnmountsEvenWhenReadingFails() {
        let mounter = FakeMounter()
        mounter.config = nil   // mounted, but no grub.cfg
        let result = reader(disks: FakeDisks(partition: partition()), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertNil(result.version)
        XCTAssertEqual(mounter.unmounts.count, 1)

        let garbage = FakeMounter()
        garbage.config = "\u{0}\u{1} not grub"
        XCTAssertNil(reader(disks: FakeDisks(partition: partition()), mounter: garbage)
            .readVersion(volumeURL: volume).version)
        XCTAssertEqual(garbage.unmounts.count, 1)
    }

    func testAlreadyMountedPartitionIsReadInPlace() throws {
        let existing = root.appendingPathComponent("VTOYEFI", isDirectory: true)
        try FileManager.default.createDirectory(at: existing.appendingPathComponent("grub"),
                                                withIntermediateDirectories: true)
        try grub.write(to: existing.appendingPathComponent("grub/grub.cfg"), atomically: true, encoding: .utf8)
        let mounter = FakeMounter()
        let result = reader(disks: FakeDisks(partition: partition(mountPoint: existing)), mounter: mounter)
            .readVersion(volumeURL: volume)
        XCTAssertEqual(result.version, VentoyVersion("1.1.18"))
        XCTAssertTrue(mounter.mounts.isEmpty)
        XCTAssertTrue(mounter.unmounts.isEmpty)
    }

    func testReadsAtMostOneMebibyte() {
        let mounter = FakeMounter()
        mounter.config = grub
        var reader = reader(disks: FakeDisks(partition: partition()), mounter: mounter)
        let limits = LimitRecorder()
        reader.readFile = { url, limit in
            limits.record(limit)
            return try? Data(contentsOf: url)
        }
        _ = reader.readVersion(volumeURL: volume)
        XCTAssertEqual(limits.values, [1 << 20])
    }
}

private final class LimitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func record(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Store

/// A reader that answers from a table and counts what it was asked.
final class FakeVentoyProbe: VentoyVersionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: VentoyVersionReading]
    private var asked: [URL] = []

    init(_ answers: [URL: VentoyVersionReading]) { self.answers = answers }

    func readVersion(volumeURL: URL) -> VentoyVersionReading {
        lock.lock(); defer { lock.unlock() }
        asked.append(volumeURL)
        return answers[volumeURL] ?? .unknown("no answer")
    }

    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return asked }
}

@MainActor
final class VentoyVersionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeVentoyStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let urlA = URL(fileURLWithPath: "/Volumes/VENTOY", isDirectory: true)
    private let urlB = URL(fileURLWithPath: "/Volumes/VENTOY 1", isDirectory: true)

    private func info(_ url: URL, uuid: String) -> VolumeInfo {
        VolumeInfo(url: url, volumeUUID: uuid, name: url.lastPathComponent, capacityBytes: 64_000_000_000,
                   availableBytes: 1_000_000_000, isReadOnly: false, isRemovable: true)
    }

    private func makeStore(probe: FakeVentoyProbe) async -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        let volumes = [urlA: info(urlA, uuid: "UUID-A"), urlB: info(urlB, uuid: "UUID-B")]
        store.driveProbe = DriveProbe(
            info: { url in
                guard let info = volumes[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in [] },
            isoSizes: { _, _ in [:] })
        store.ventoyVersionReader = probe
        await store.loadAtLaunch()
        return store
    }

    /// Lets the detached read and its main-actor landing run.
    private func settle(_ store: AppStore, _ driveID: UUID) async {
        for _ in 0..<200 where store.ventoyVersionReads[driveID] != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testResultIsShownPerDrive() async throws {
        let probe = FakeVentoyProbe([urlA: .known(VentoyVersion("1.1.10")!),
                                     urlB: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        let a = try store.registerDrive(at: urlA)
        let b = try store.registerDrive(at: urlB)
        store.scanAndReconcile(driveID: a.id)
        store.scanAndReconcile(driveID: b.id)
        await settle(store, a.id)
        await settle(store, b.id)

        let driveA = try XCTUnwrap(store.drive(id: a.id))
        let driveB = try XCTUnwrap(store.drive(id: b.id))
        XCTAssertEqual(store.ventoyVersion(for: driveA)?.version, VentoyVersion("1.1.10"))
        XCTAssertEqual(store.ventoyVersion(for: driveB)?.version, VentoyVersion("1.1.18"))
        XCTAssertTrue(store.ventoyVersion(for: driveA)?.needsSecureBootCANotice == true)
        XCTAssertFalse(store.ventoyVersion(for: driveB)?.needsSecureBootCANotice == true)
    }

    func testReadsOncePerConnectNotOnEveryScan() async throws {
        let probe = FakeVentoyProbe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        let drive = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: drive.id)
        await settle(store, drive.id)
        store.scanAndReconcile(driveID: drive.id)
        store.scanAndReconcile(driveID: drive.id)
        await settle(store, drive.id)
        XCTAssertEqual(probe.calls.count, 1)

        // Unplug and replug: a new connect reads again.
        store.markDisconnected(volumeUUID: "UUID-A")
        XCTAssertNil(store.ventoyVersions[drive.id])
        store.markConnected(try XCTUnwrap(store.drive(id: drive.id)), info: info(urlA, uuid: "UUID-A"))
        store.scanAndReconcile(driveID: drive.id)
        await settle(store, drive.id)
        XCTAssertEqual(probe.calls.count, 2)
    }

    func testNoReadWhileAnOperationRunsOnTheDrive() async throws {
        let probe = FakeVentoyProbe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        let drive = try store.registerDrive(at: urlA)
        store.drivesWithOperationsInFlight.insert(drive.id)
        store.scanAndReconcile(driveID: drive.id)
        store.refreshVentoyVersion(driveID: drive.id)
        XCTAssertNil(store.ventoyVersionReads[drive.id])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(probe.calls.isEmpty)

        // When the pipeline lets go, the read happens.
        store.drivesWithOperationsInFlight.remove(drive.id)
        await settle(store, drive.id)
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(store.ventoyVersion(for: try XCTUnwrap(store.drive(id: drive.id)))?.version,
                       VentoyVersion("1.1.18"))
    }

    func testNoReadWhileAnyFlashRuns() async throws {
        let probe = FakeVentoyProbe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        let drive = try store.registerDrive(at: urlA)
        var flashed = ManagedDrive(volumeUUID: "FLASHED", displayName: "Stick", bookmark: Data(),
                                   capacityBytes: 16_000_000_000)
        flashed.kind = .flashed
        store.addDrive(flashed)
        store.drivesWithOperationsInFlight.insert(flashed.id)
        store.refreshVentoyVersion(driveID: drive.id)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testResultFromBeforeAnUnplugIsDropped() async throws {
        let probe = FakeVentoyProbe([:])
        let store = await makeStore(probe: probe)
        let drive = try store.registerDrive(at: urlA)
        store.ventoyVersionReads[drive.id] = UUID()
        let stale = UUID()
        store.finishVentoyVersionRead(.known(VentoyVersion("1.0.1")!), driveID: drive.id, token: stale)
        XCTAssertNil(store.ventoyVersions[drive.id])
    }

    func testEjectIsHeldWhileReading() async throws {
        let store = await makeStore(probe: FakeVentoyProbe([:]))
        let drive = try store.registerDrive(at: urlA)
        store.ventoyVersionReads[drive.id] = UUID()
        XCTAssertFalse(store.canEject(drive))
        store.ventoyVersionReads[drive.id] = nil
        XCTAssertTrue(store.canEject(drive))
    }

    func testUnknownReadingShowsButNeverWarns() async throws {
        let store = await makeStore(probe: FakeVentoyProbe([:]))
        let drive = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: drive.id)
        await settle(store, drive.id)
        let reading = try XCTUnwrap(store.ventoyVersion(for: try XCTUnwrap(store.drive(id: drive.id))))
        XCTAssertNil(reading.version)
        XCTAssertFalse(reading.needsSecureBootCANotice)
    }
}
