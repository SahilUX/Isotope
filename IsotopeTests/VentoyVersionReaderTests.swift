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

    /// Answers each `snapshot` call from a script: the first call gets the
    /// first entry, and the last entry repeats.
    private final class FakeDisks: VentoyDiskInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [VentoyDiskSnapshot?]
        private(set) var calls = 0
        init(_ script: [VentoyDiskSnapshot?]) { self.script = script }
        convenience init(_ snapshot: VentoyDiskSnapshot?) { self.init([snapshot]) }
        func snapshot(forVolumeAt url: URL) -> VentoyDiskSnapshot? {
            lock.lock(); defer { lock.unlock() }
            let index = min(calls, script.count - 1)
            calls += 1
            return script[index]
        }
    }

    private final class FakeMounter: PartitionMounting, @unchecked Sendable {
        private let lock = NSLock()
        var mountSucceeds = true
        /// A mount that "fails" but leaves something mounted (a timeout).
        var leavesMountedOnFailure = false
        /// How many unmount calls fail before one succeeds; -1 never succeeds.
        var unmountFailures = 0
        /// Written into the mount directory when the mount succeeds.
        var config: String?
        private(set) var mounts: [(String, URL)] = []
        private(set) var unmounts: [URL] = []
        private(set) var identityChecks = 0
        private var mounted: Set<URL> = []

        func mountReadOnly(devicePath: String, at directory: URL,
                           isStillSameDevice: () -> Bool) -> VentoyMountOutcome {
            identityChecks += 1
            guard isStillSameDevice() else { return .identityChanged }
            lock.lock(); defer { lock.unlock() }
            mounts.append((devicePath, directory))
            if mountSucceeds, let config {
                let grub = directory.appendingPathComponent("grub", isDirectory: true)
                try? FileManager.default.createDirectory(at: grub, withIntermediateDirectories: true)
                try? config.write(to: grub.appendingPathComponent("grub.cfg"), atomically: true, encoding: .utf8)
            }
            if mountSucceeds || leavesMountedOnFailure { mounted.insert(directory) }
            return mountSucceeds ? .mounted : .failed
        }

        func isMounted(at directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return mounted.contains(directory)
        }

        func markMounted(_ directory: URL) {
            lock.lock(); defer { lock.unlock() }
            mounted.insert(directory)
        }

        func unmount(directory: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            unmounts.append(directory)
            if unmountFailures != 0 {
                if unmountFailures > 0 { unmountFailures -= 1 }
                return false
            }
            mounted.remove(directory)
            // Stand-in for the mounted filesystem going away.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("grub"))
            return true
        }
    }

    private func snapshot(whole: String = "disk9", partitionWhole: String = "disk9",
                          name: String = "disk9s2", dataPartition: String = "disk9s1",
                          volumeUUID: String? = "UUID-A", mediaUUID: String = "MEDIA-1",
                          size: Int64 = 32 * 1024 * 1024, content: String = "0xEF",
                          volumeName: String? = "VTOYEFI", isUSB: Bool = true,
                          mountPoint: URL? = nil) -> VentoyDiskSnapshot {
        VentoyDiskSnapshot(
            dataPartitionBSDName: dataPartition, dataVolumeUUID: volumeUUID,
            wholeDisk: VentoyDiskIdentity(bsdName: whole, mediaUUID: mediaUUID,
                                          mediaPath: "IODeviceTree:/usb/\(mediaUUID)", devicePath: nil,
                                          hardwareID: HardwareID(vendorID: 1, productID: 2, serialNumber: "S1")),
            efi: VentoyEFIPartitionInfo(
                candidate: VentoyEFIPartitionCandidate(
                    dataWholeDisk: whole, partitionBSDName: name, partitionWholeDisk: partitionWhole,
                    sizeBytes: size, content: content,
                    disk: FlashDeviceDescription(bsdName: whole, displayName: "Stick",
                                                 sizeBytes: 64_000_000_000, isUSB: isUSB),
                    dataPartitionBSDName: dataPartition, volumeName: volumeName),
                mountPoint: mountPoint))
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

    private let expected = VentoyExpectedIdentity(volumeUUID: "UUID-A", wholeDisk: "disk9",
                                                  hardwareID: HardwareID(vendorID: 1, productID: 2,
                                                                         serialNumber: "S1"))

    private func read(_ disks: FakeDisks, _ mounter: FakeMounter,
                      expected: VentoyExpectedIdentity? = nil) -> VentoyProbeResult {
        reader(disks: disks, mounter: mounter).readVersion(volumeURL: volume, expected: expected ?? self.expected)
    }

    private let grub = "function x {\n}\nset VENTOY_VERSION=\"1.1.18\"\n"
    private let volume = URL(fileURLWithPath: "/Volumes/Ventoy")

    // MARK: Eligibility

    func testWrongSizeIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(snapshot(size: 300 * 1024 * 1024)), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testWrongTypeOrNameIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(snapshot(content: "Windows_NTFS")), mounter).reading.version)
        XCTAssertNil(read(FakeDisks(snapshot(volumeName: "EFI")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testPartitionOnAnotherWholeDiskIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(snapshot(partitionWhole: "disk3", name: "disk3s2")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testDataVolumeThatIsNotPartitionOneIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(snapshot(dataPartition: "disk9s3")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testNonUSBDiskIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(snapshot(isUSB: false)), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testUnidentifiedDiskIsUnknown() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(nil), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    // MARK: Identity

    func testReplacedVolumePathIsNotMounted() {
        // Another stick now answers at the registered drive's mount path.
        let mounter = FakeMounter()
        mounter.config = grub
        let result = read(FakeDisks(snapshot(volumeUUID: "UUID-OTHER")), mounter)
        XCTAssertNil(result.reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testDriveOnAnotherDiskOrDeviceThanExpectedIsNotMounted() {
        let mounter = FakeMounter()
        mounter.config = grub
        XCTAssertNil(read(FakeDisks(snapshot(whole: "disk5", partitionWhole: "disk5", name: "disk5s2",
                                             dataPartition: "disk5s1")), mounter).reading.version)
        var other = expected
        other.hardwareID = HardwareID(vendorID: 1, productID: 2, serialNumber: "S2")
        XCTAssertNil(read(FakeDisks(snapshot()), mounter, expected: other).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testReusedBSDNameBeforeMountAbortsWithoutMounting() {
        // First look: the drive. By the mount attempt, disk9 is a different
        // disk with the same layout (macOS reused the BSD name).
        let mounter = FakeMounter()
        mounter.config = grub
        let result = read(FakeDisks([snapshot(), snapshot(mediaUUID: "MEDIA-2")]), mounter)
        XCTAssertNil(result.reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
        XCTAssertEqual(mounter.identityChecks, 1)
    }

    func testIdentityChangeRightAfterMountIsUnmountedUnread() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        // 1: first look, 2: before the mount attempt, 3: right after it.
        let result = read(FakeDisks([snapshot(), snapshot(), snapshot(mediaUUID: "MEDIA-2")]), mounter)
        XCTAssertNil(result.reading.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(mounter.unmounts, [directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOwnMountDoesNotCountAsAnIdentityChange() {
        // After mounting, DiskArbitration reports where VTOYEFI is mounted.
        let mounter = FakeMounter()
        mounter.config = grub
        let after = snapshot(mountPoint: URL(fileURLWithPath: "/private/tmp/isotope-vtoyefi-x"))
        XCTAssertEqual(read(FakeDisks([snapshot(), snapshot(), after]), mounter).reading.version,
                       VentoyVersion("1.1.18"))
    }

    // MARK: Mount, read, unmount

    func testReadsVersionAndUnmountsAndRemovesFolder() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        let disks = FakeDisks(snapshot())
        let result = read(disks, mounter)
        XCTAssertEqual(result, VentoyProbeResult(.known(VentoyVersion("1.1.18")!)))
        XCTAssertEqual(mounter.mounts.map(\.0), ["/dev/disk9s2"])
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(mounter.unmounts, [directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(disks.calls, 3, "described before the read, before the mount and after it")
    }

    func testFailedMountIsUnknownAndLeavesNoFolder() throws {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        let result = read(FakeDisks(snapshot()), mounter)
        XCTAssertNil(result.reading.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertTrue(mounter.unmounts.isEmpty, "nothing was mounted, so nothing to unmount")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedMountThatLeftAMountIsStillUnmounted() {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        mounter.leavesMountedOnFailure = true
        _ = read(FakeDisks(snapshot()), mounter)
        XCTAssertEqual(mounter.unmounts.count, 1)
    }

    func testUnmountsEvenWhenReadingFails() {
        let mounter = FakeMounter()
        mounter.config = nil   // mounted, but no grub.cfg
        XCTAssertNil(read(FakeDisks(snapshot()), mounter).reading.version)
        XCTAssertEqual(mounter.unmounts.count, 1)

        let garbage = FakeMounter()
        garbage.config = "\u{0}\u{1} not grub"
        XCTAssertNil(read(FakeDisks(snapshot()), garbage).reading.version)
        XCTAssertEqual(garbage.unmounts.count, 1)
    }

    func testUnmountFailureIsReportedAndKeepsTheMountRecorded() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        mounter.unmountFailures = -1
        let result = read(FakeDisks(snapshot()), mounter)
        XCTAssertEqual(result.reading, .unknown("cleanup failed"))
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(result.leftoverMount, directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                      "a folder that may still be a mount point is never removed")
    }

    func testAlreadyMountedPartitionIsReadInPlace() throws {
        let existing = root.appendingPathComponent("VTOYEFI", isDirectory: true)
        try FileManager.default.createDirectory(at: existing.appendingPathComponent("grub"),
                                                withIntermediateDirectories: true)
        try grub.write(to: existing.appendingPathComponent("grub/grub.cfg"), atomically: true, encoding: .utf8)
        let mounter = FakeMounter()
        let result = read(FakeDisks(snapshot(mountPoint: existing)), mounter)
        XCTAssertEqual(result.reading.version, VentoyVersion("1.1.18"))
        XCTAssertTrue(mounter.mounts.isEmpty)
        XCTAssertTrue(mounter.unmounts.isEmpty)
    }

    func testReadsAtMostOneMebibyte() {
        let mounter = FakeMounter()
        mounter.config = grub
        var reader = reader(disks: FakeDisks(snapshot()), mounter: mounter)
        let limits = LimitRecorder()
        reader.readFile = { url, limit in
            limits.record(limit)
            return try? Data(contentsOf: url)
        }
        _ = reader.readVersion(volumeURL: volume, expected: expected)
        XCTAssertEqual(limits.values, [1 << 20])
    }

    // MARK: Leftover mounts

    func testJanitorUnmountsAndRemovesOnlyItsOwnFolders() throws {
        let mine = root.appendingPathComponent("isotope-vtoyefi-A", isDirectory: true)
        let mounted = root.appendingPathComponent("isotope-vtoyefi-B", isDirectory: true)
        let other = root.appendingPathComponent("something-else", isDirectory: true)
        for url in [mine, mounted, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let mounter = FakeMounter()
        mounter.markMounted(mounted)
        let janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        XCTAssertEqual(Set(janitor.leftovers()), [mine, mounted])
        XCTAssertEqual(janitor.cleanUpLeftovers(), [])
        XCTAssertEqual(mounter.unmounts, [mounted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mounted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testJanitorNeverEmptiesAFolder() throws {
        // A folder with something in it (a mount that is somehow still there,
        // as far as the janitor can tell) is left exactly as it is.
        let folder = root.appendingPathComponent("isotope-vtoyefi-C", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("file"))
        let janitor = VentoyMountJanitor(mounter: FakeMounter(), temporaryDirectory: root)
        XCTAssertEqual(janitor.cleanUpLeftovers(), [folder])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("file").path))

        let stuck = root.appendingPathComponent("isotope-vtoyefi-D", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        let mounter = FakeMounter()
        mounter.markMounted(stuck)
        mounter.unmountFailures = -1
        XCTAssertFalse(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(stuck))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
    }

    // MARK: Bounded processes

    private final class FakeProcess: ManagedProcess {
        var isRunning = true
        var terminationStatus: Int32 = 0
        var exitsOnTerminate = false
        var exitsOnKill = false
        private(set) var terminates = 0
        private(set) var kills = 0
        func terminate() { terminates += 1; if exitsOnTerminate { isRunning = false } }
        func kill() { kills += 1; if exitsOnKill { isRunning = false } }
    }

    func testProcessThatExitsInTimeReportsItsStatus() {
        let process = FakeProcess()
        process.isRunning = false
        process.terminationStatus = 3
        XCTAssertEqual(ProcessRunner.wait(for: process, timeout: 0.05), .exited(3))
        XCTAssertEqual(process.terminates, 0)
    }

    func testProcessIgnoringSIGTERMIsKilled() {
        let process = FakeProcess()
        process.exitsOnKill = true
        let outcome = ProcessRunner.wait(for: process, timeout: 0.05, terminateGrace: 0.05, killGrace: 0.05,
                                         pollInterval: 0.005)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(process.terminates, 1)
        XCTAssertEqual(process.kills, 1)
    }

    func testProcessSurvivingSIGKILLIsAbandonedWithinTheBound() {
        let process = FakeProcess()
        let started = Date()
        let outcome = ProcessRunner.wait(for: process, timeout: 0.05, terminateGrace: 0.05, killGrace: 0.05,
                                         pollInterval: 0.005)
        XCTAssertEqual(outcome, .abandoned)
        XCTAssertEqual(process.kills, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRealChildIgnoringSIGTERMIsKilled() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30"]
        try process.run()
        let started = Date()
        let outcome = ProcessRunner.wait(for: LiveProcess(process), timeout: 0.2, terminateGrace: 0.3,
                                         killGrace: 2)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

private final class LimitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func record(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Store

/// A reader that answers from a table and counts what it was asked. With
/// `blocking`, each read waits until the test calls `release()`.
final class FakeVentoyProbe: VentoyVersionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: VentoyProbeResult]
    private var asked: [(URL, VentoyExpectedIdentity)] = []
    private let gate: DispatchSemaphore?
    private var released = false

    init(_ answers: [URL: VentoyVersionReading], blocking: Bool = false) {
        self.answers = answers.mapValues { VentoyProbeResult($0) }
        gate = blocking ? DispatchSemaphore(value: 0) : nil
    }

    func set(_ result: VentoyProbeResult, for url: URL) { lock.withLock { answers[url] = result } }

    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity) -> VentoyProbeResult {
        lock.withLock { asked.append((volumeURL, expected)) }
        gate?.wait()
        return lock.withLock { answers[volumeURL] ?? VentoyProbeResult(.unknown("no answer")) }
    }

    /// Lets every blocked read (and every later one) through. Safe to call twice.
    func release() {
        let first: Bool = lock.withLock {
            defer { released = true }
            return !released
        }
        guard first, let gate else { return }
        for _ in 0..<64 { gate.signal() }
    }

    var calls: [URL] { lock.withLock { asked.map(\.0) } }
    var expectations: [VentoyExpectedIdentity] { lock.withLock { asked.map(\.1) } }
}

@MainActor
final class VentoyVersionStoreTests: XCTestCase {
    private var root: URL!
    private var probes: [FakeVentoyProbe] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeVentoyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Reads share one serial queue: never leave one blocked for the next test.
        probes.forEach { $0.release() }
        try? FileManager.default.removeItem(at: root)
    }

    private let urlA = URL(fileURLWithPath: "/Volumes/VENTOY", isDirectory: true)
    private let urlB = URL(fileURLWithPath: "/Volumes/VENTOY 1", isDirectory: true)

    private func info(_ url: URL, uuid: String) -> VolumeInfo {
        VolumeInfo(url: url, volumeUUID: uuid, name: url.lastPathComponent, capacityBytes: 64_000_000_000,
                   availableBytes: 1_000_000_000, isReadOnly: false, isRemovable: true)
    }

    private func probe(_ answers: [URL: VentoyVersionReading], blocking: Bool = false) -> FakeVentoyProbe {
        let probe = FakeVentoyProbe(answers, blocking: blocking)
        probes.append(probe)
        return probe
    }

    private func makeStore(probe: FakeVentoyProbe, volumes extra: [URL: VolumeInfo] = [:]) async -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        var volumes = [urlA: info(urlA, uuid: "UUID-A"), urlB: info(urlB, uuid: "UUID-B")]
        volumes.merge(extra) { $1 }
        let known = volumes
        store.driveProbe = DriveProbe(
            info: { url in
                guard let info = known[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in [] },
            isoSizes: { _, _ in [:] })
        store.ventoyVersionReader = probe
        await store.loadAtLaunch()
        return store
    }

    /// The stick the Ventoy drive at `urlA` lives on, as the device list sees it.
    private func device(volumeUUIDs: [String] = ["UUID-A"]) -> FlashDevice {
        FlashDevice(bsdName: "disk4", displayName: "SanDisk Cruzer Blade", sizeBytes: 32 << 30,
                    isWholeDisk: true, isExternal: true, isRemovableOrEjectable: true, isUSB: true,
                    isBootDisk: false,
                    hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: "SERIAL-1"),
                    volumeNames: ["VENTOY"], volumeUUIDs: volumeUUIDs)
    }

    /// Lets the queued read and its main-actor landing run.
    private func settle(_ store: AppStore, _ driveID: UUID) async {
        for _ in 0..<400 where store.ventoyVersionReads[driveID] != nil || !store.ventoyProbes.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Registers the drive at `urlA` and starts its read.
    private func startRead(_ store: AppStore) throws -> ManagedDrive {
        let drive = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: drive.id)
        return try XCTUnwrap(store.drive(id: drive.id))
    }

    func testResultIsShownPerDrive() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.10")!), urlB: .known(VentoyVersion("1.1.18")!)])
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

    func testReaderIsGivenTheRegisteredIdentity() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        store.attachedDevices = [device()]
        let drive = try startRead(store)
        await settle(store, drive.id)
        XCTAssertEqual(probe.expectations, [VentoyExpectedIdentity(
            volumeUUID: "UUID-A", wholeDisk: "disk4",
            hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: "SERIAL-1"))])
    }

    func testReadsOncePerConnectNotOnEveryScan() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        let drive = try startRead(store)
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
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)])
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
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)])
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
        let probe = probe([:])
        let store = await makeStore(probe: probe)
        let drive = try store.registerDrive(at: urlA)
        store.ventoyVersionReads[drive.id] = UUID()
        let stale = UUID()
        store.finishVentoyVersionRead(VentoyProbeResult(.known(VentoyVersion("1.0.1")!)),
                                      driveID: drive.id, token: stale)
        XCTAssertNil(store.ventoyVersions[drive.id])
    }

    func testUnknownReadingShowsButNeverWarns() async throws {
        let store = await makeStore(probe: probe([:]))
        let drive = try startRead(store)
        await settle(store, drive.id)
        let reading = try XCTUnwrap(store.ventoyVersion(for: try XCTUnwrap(store.drive(id: drive.id))))
        XCTAssertNil(reading.version)
        XCTAssertFalse(reading.needsSecureBootCANotice)
    }

    func testDisabledReaderStartsNothingAndHoldsNothing() async throws {
        let store = await makeStore(probe: probe([:]))
        store.ventoyVersionReader = DisabledVentoyVersionReader()
        let drive = try startRead(store)
        XCTAssertTrue(store.ventoyProbes.isEmpty)
        XCTAssertNil(store.ventoyVersionReads[drive.id])
        XCTAssertTrue(store.canEject(drive))
    }

    // MARK: Two-way exclusion

    func testEjectAndDeleteAreHeldWhileReading() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        let drive = try startRead(store)
        XCTAssertTrue(store.isReadingVentoyVersion(drive))
        XCTAssertFalse(store.canEject(drive))
        XCTAssertEqual(store.ejectBlocker(drive), AppStore.ventoyReadFinishing)
        XCTAssertEqual(store.deleteBlocker(fileName: "a.iso", on: drive), AppStore.ventoyReadFinishing)
        XCTAssertThrowsError(try store.deleteISO(fileName: "a.iso", on: drive.id))
        try store.eject(driveID: drive.id)   // refused: still connected
        XCTAssertTrue(store.isConnected(drive))

        probe.release()
        await settle(store, drive.id)
        XCTAssertFalse(store.isReadingVentoyVersion(drive))
        XCTAssertTrue(store.canEject(drive))
        XCTAssertNil(store.deleteBlocker(fileName: "a.iso", on: drive))
    }

    func testReadHoldsTheSameStickRegisteredAsAFlashedDrive() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        store.attachedDevices = [device()]
        var flashed = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade", bookmark: Data(),
                                   capacityBytes: 32 << 30)
        flashed.kind = .flashed
        flashed.hardwareID = HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: "SERIAL-1")
        store.addDrive(flashed)
        _ = try startRead(store)
        XCTAssertTrue(store.isReadingVentoyVersion(flashed))
        XCTAssertTrue(store.isReadingVentoyVersion(bsdName: "disk4"))
        XCTAssertFalse(store.isReadingVentoyVersion(bsdName: "disk7"), "another stick is not held")
        XCTAssertFalse(store.canEject(flashed))
        probe.release()
    }

    func testManualCopyWaitsForTheRead() async throws {
        let volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let probe = probe([volume: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe, volumes: [volume: info(volume, uuid: "UUID-V")])
        let writer = FakeDriveWriter()
        let engine = UpdateEngine(store: store, downloads: FakeISOProvider(behaviour: .failure(CocoaError(.fileNoSuchFile))),
                                  drives: writer)
        store.updateEngine = engine
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertTrue(store.isReadingVentoyVersion(drive))

        let source = try TestFiles.write(root.appendingPathComponent("notes.txt"), size: 4096)
        let file = try LocalFile(url: source)
        let request = UpdateRequest(driveID: drive.id, driveName: "VENTOY", assignmentID: UUID(),
                                    entryID: "local-file", channelID: "local", title: file.name,
                                    release: file.release, isLocalFile: true)
        await engine.enqueueManual(request, sourceFile: source, fileName: file.name)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let copied = volume.appendingPathComponent("notes.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path), "nothing is written mid-read")
        XCTAssertEqual(writer.accessBalance, 0, "the drive was not even opened")

        probe.release()
        await engine.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(store.operations.first?.phase, .completed)
    }

    func testFlashWaitsForAReadOnTheSameDisk() async throws {
        let store = await makeStore(probe: probe([:]))
        var flashed = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade", bookmark: Data(),
                                   assignments: [Assignment(entryID: "arch", channelID: "default")],
                                   capacityBytes: 32 << 30, kind: .flashed,
                                   hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583,
                                                          serialNumber: "SERIAL-1"),
                                   lastBSDName: "disk4")
        flashed.kind = .flashed
        store.addDrive(flashed)
        let iso = try TestFiles.write(root.appendingPathComponent("arch.iso"), size: 128 * 1024)
        let release = Release(version: VersionToken.parse("2026.08.01")!,
                              isoURL: URL(string: "https://example.com/arch.iso")!, fileName: "arch.iso",
                              sha256: nil, sizeBytes: 128 * 1024, checkedAt: Date())
        let io = FakeFlashDeviceIO(description: FlashDeviceDescription(bsdName: "disk4",
                                                                       displayName: "SanDisk Cruzer Blade",
                                                                       sizeBytes: 32 << 30))
        let engine = FlashEngine(store: store, downloads: FakeISOProvider(behaviour: .file(iso)), io: io,
                                 hashing: store.hashing)
        // A read holding disk4 for some other registration of the same stick.
        let token = UUID()
        store.ventoyProbes[token] = VentoyProbeHold(driveID: UUID(), volumeUUID: "UUID-OTHER", wholeDisk: "disk4")

        let request = FlashRequest(driveID: flashed.id, driveName: flashed.displayName,
                                   assignmentID: flashed.assignments[0].id, entryID: "arch", channelID: "default",
                                   title: "Arch Linux", release: release, bsdName: "disk4",
                                   deviceName: "SanDisk Cruzer Blade", verifyAfterWrite: false)
        await engine.enqueue(request)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(io.describeCount, 0, "the flash has not started")
        XCTAssertEqual(io.unmountCount, 0)
        XCTAssertTrue(io.written.isEmpty)

        store.finishVentoyVersionRead(VentoyProbeResult(.unknown("x")), driveID: UUID(), token: token)
        await engine.drain()
        XCTAssertEqual(io.written.count, 128 * 1024)
    }

    // MARK: Cap, disconnects, cleanup

    func testCapReleasesTheHoldButKeepsTheReadAccountedFor() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        store.ventoyVersionReadCap = 0.1
        let drive = try startRead(store)
        XCTAssertFalse(store.canEject(drive))
        await waitUntil { store.canEject(drive) }
        XCTAssertEqual(store.ventoyVersions[drive.id], .unknown("Reading the Ventoy version took too long"))
        XCTAssertEqual(store.ventoyProbes.count, 1, "the read is still running")
        XCTAssertEqual(store.ventoyProbes.values.first?.holdsDevice, false)
        // No second read starts next to the one still running.
        store.markDisconnected(volumeUUID: "UUID-A")
        store.markConnected(drive, info: info(urlA, uuid: "UUID-A"))
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertNil(store.ventoyVersionReads[drive.id])

        probe.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        XCTAssertNil(store.ventoyVersions[drive.id], "the late result belongs to no connect")
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testUnregisterDuringAReadStillTracksIt() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        let drive = try startRead(store)
        store.unregisterDrive(id: drive.id)
        XCTAssertNil(store.ventoyVersionReads[drive.id])
        XCTAssertEqual(store.ventoyProbes.count, 1)
        XCTAssertTrue(store.isReadingVentoyVersion(bsdName: "disk4"), "an unknown disk holds every flash")
        probe.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        XCTAssertNil(store.ventoyVersions[drive.id])
    }

    func testQuitWaitsBoundedForAReadStillRunning() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        _ = try startRead(store)
        let started = Date()
        await store.drainVentoyVersionReads(timeout: 0.2)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.15)
        XCTAssertLessThan(waited, 1.5)
        XCTAssertEqual(store.ventoyProbes.count, 1)
    }

    func testQuitDrainsAFinishingReadAndUndoesItsLeftoverMount() async throws {
        let leftover = root.appendingPathComponent("isotope-vtoyefi-L", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let probe = probe([:], blocking: true)
        probe.set(VentoyProbeResult(.unknown("cleanup failed"), leftoverMount: leftover), for: urlA)
        let store = await makeStore(probe: probe)
        let mounter = StubMounter(mounted: [leftover])
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        let drive = try startRead(store)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); probe.release() }
        await store.drainVentoyVersionReads(timeout: 3)
        XCTAssertTrue(store.ventoyProbes.isEmpty)
        XCTAssertTrue(store.ventoyLeftoverMounts.isEmpty)
        XCTAssertEqual(mounter.unmounted, [leftover])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(store.ventoyVersions[drive.id], .unknown("cleanup failed"))
        XCTAssertTrue(store.canEject(try XCTUnwrap(store.drive(id: drive.id))), "Eject is not held forever")
    }

    func testLaunchCleansUpLeftoverFolders() async throws {
        let leftover = root.appendingPathComponent("isotope-vtoyefi-M", isDirectory: true)
        let stuck = root.appendingPathComponent("isotope-vtoyefi-N", isDirectory: true)
        for url in [leftover, stuck] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = await makeStore(probe: probe([:]))
        let mounter = StubMounter(mounted: [leftover, stuck], stuck: [stuck])
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        store.cleanUpLeftoverVentoyMounts()
        await waitUntil { store.ventoyLeftoverMounts == [stuck] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
    }
}

/// Mount state from a list, for the janitor.
private final class StubMounter: PartitionMounting, @unchecked Sendable {
    private let lock = NSLock()
    private var mounted: Set<URL>
    private let stuck: Set<URL>
    private var unmountedList: [URL] = []

    init(mounted: Set<URL>, stuck: Set<URL> = []) {
        self.mounted = mounted
        self.stuck = stuck
    }

    var unmounted: [URL] { lock.withLock { unmountedList } }

    func mountReadOnly(devicePath: String, at directory: URL,
                       isStillSameDevice: () -> Bool) -> VentoyMountOutcome { .failed }
    func isMounted(at directory: URL) -> Bool { lock.withLock { mounted.contains(directory) } }
    func unmount(directory: URL) -> Bool {
        lock.withLock {
            guard !stuck.contains(directory) else { return false }
            unmountedList.append(directory)
            mounted.remove(directory)
            return true
        }
    }
}
