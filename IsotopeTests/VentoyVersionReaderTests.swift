import Foundation
import IsotopeCore
import XCTest
@testable import Isotope

// MARK: - Fakes

/// Answers each `snapshot` call from a script: the first call gets the
/// first entry, and the last entry repeats.
final class FakeDisks: VentoyDiskInspecting, @unchecked Sendable {
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

final class FakeMounter: PartitionMounting, @unchecked Sendable {
    private let lock = NSLock()
    var mountSucceeds = true
    /// A mount that "fails" but leaves something mounted (a timeout).
    var leavesMountedOnFailure = false
    /// How many unmount calls fail before one succeeds; -1 never succeeds.
    var unmountFailures = 0
    /// The mount tool outlives SIGKILL: the attempt reports `.abandoned` and
    /// nothing is mounted yet. A test calls `markMounted` for the mount that
    /// "appears" after the reader has returned.
    var abandons = false
    /// Written into the mount directory when the mount succeeds.
    var config: String?
    private(set) var mounts: [(String, URL)] = []
    private(set) var unmounts: [URL] = []
    private(set) var identityChecks = 0
    private var mounted: Set<URL> = []

    /// What `mountInfo` reports for a mounted directory; defaults to our own
    /// read-only FAT mount of a partition 2.
    var info: (URL) -> VentoyMountInfo = { directory in
        VentoyMountInfo(mountedOn: directory.path, mountedFrom: "/dev/disk9s2", fileSystem: "msdos",
                        isReadOnly: true)
    }

    func mountReadOnly(devicePath: String, at directory: URL,
                       isStillSameDevice: () -> Bool) -> VentoyMountOutcome {
        identityChecks += 1
        guard isStillSameDevice() else { return .identityChanged }
        lock.lock(); defer { lock.unlock() }
        mounts.append((devicePath, directory))
        if abandons { return .abandoned }
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

    func mountInfo(at directory: URL) -> VentoyMountInfo? {
        isMounted(at: directory) ? info(directory) : nil
    }

    var mountCount: Int { lock.withLock { mounts.count } }

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

func ventoySnapshot(whole: String = "disk9", partitionWhole: String = "disk9",
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
        reader(disks: disks, mounter: mounter).readVersion(volumeURL: volume, expected: expected ?? self.expected,
                                                           ticket: activeTicket())
    }

    private func activeTicket() -> VentoyReadTicket {
        let ticket = VentoyReadTicket()
        XCTAssertTrue(ticket.activate())
        return ticket
    }

    private let grub = "function x {\n}\nset VENTOY_VERSION=\"1.1.18\"\n"
    private let volume = URL(fileURLWithPath: "/Volumes/Ventoy")

    // MARK: Eligibility

    func testWrongSizeIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(ventoySnapshot(size: 300 * 1024 * 1024)), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testWrongTypeOrNameIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(ventoySnapshot(content: "Windows_NTFS")), mounter).reading.version)
        XCTAssertNil(read(FakeDisks(ventoySnapshot(volumeName: "EFI")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testPartitionOnAnotherWholeDiskIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(ventoySnapshot(partitionWhole: "disk3", name: "disk3s2")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testDataVolumeThatIsNotPartitionOneIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(ventoySnapshot(dataPartition: "disk9s3")), mounter).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testNonUSBDiskIsNotMounted() {
        let mounter = FakeMounter()
        XCTAssertNil(read(FakeDisks(ventoySnapshot(isUSB: false)), mounter).reading.version)
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
        let result = read(FakeDisks(ventoySnapshot(volumeUUID: "UUID-OTHER")), mounter)
        XCTAssertNil(result.reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testDriveOnAnotherDiskOrDeviceThanExpectedIsNotMounted() {
        let mounter = FakeMounter()
        mounter.config = grub
        XCTAssertNil(read(FakeDisks(ventoySnapshot(whole: "disk5", partitionWhole: "disk5", name: "disk5s2",
                                             dataPartition: "disk5s1")), mounter).reading.version)
        var other = expected
        other.hardwareID = HardwareID(vendorID: 1, productID: 2, serialNumber: "S2")
        XCTAssertNil(read(FakeDisks(ventoySnapshot()), mounter, expected: other).reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
    }

    func testReusedBSDNameBeforeMountAbortsWithoutMounting() {
        // First look: the drive. By the mount attempt, disk9 is a different
        // disk with the same layout (macOS reused the BSD name).
        let mounter = FakeMounter()
        mounter.config = grub
        let result = read(FakeDisks([ventoySnapshot(), ventoySnapshot(mediaUUID: "MEDIA-2")]), mounter)
        XCTAssertNil(result.reading.version)
        XCTAssertTrue(mounter.mounts.isEmpty)
        XCTAssertEqual(mounter.identityChecks, 1)
    }

    func testIdentityChangeRightAfterMountIsUnmountedUnread() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        // 1: first look, 2: before the mount attempt, 3: right after it.
        let result = read(FakeDisks([ventoySnapshot(), ventoySnapshot(), ventoySnapshot(mediaUUID: "MEDIA-2")]), mounter)
        XCTAssertNil(result.reading.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(mounter.unmounts, [directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    func testOwnMountDoesNotCountAsAnIdentityChange() {
        // After mounting, DiskArbitration reports where VTOYEFI is mounted.
        let mounter = FakeMounter()
        mounter.config = grub
        let after = ventoySnapshot(mountPoint: URL(fileURLWithPath: "/private/tmp/isotope-vtoyefi-x"))
        XCTAssertEqual(read(FakeDisks([ventoySnapshot(), ventoySnapshot(), after]), mounter).reading.version,
                       VentoyVersion("1.1.18"))
    }

    // MARK: Mount, read, unmount

    func testReadsVersionAndUnmountsAndRemovesFolder() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        let disks = FakeDisks(ventoySnapshot())
        let result = read(disks, mounter)
        XCTAssertEqual(result, VentoyProbeResult(.known(VentoyVersion("1.1.18")!)))
        XCTAssertEqual(mounter.mounts.map(\.0), ["/dev/disk9s2"])
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertEqual(directory.lastPathComponent, "m", "the mount point is <container>/m")
        XCTAssertEqual(mounter.unmounts, [directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path),
                       "the container is removed too")
        XCTAssertEqual(disks.calls, 3, "described before the read, before the mount and after it")
    }

    func testFailedMountIsUnknownAndLeavesNoFolder() throws {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        let result = read(FakeDisks(ventoySnapshot()), mounter)
        XCTAssertNil(result.reading.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        XCTAssertTrue(mounter.unmounts.isEmpty, "nothing was mounted, so nothing to unmount")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    func testFailedMountThatLeftAMountIsStillUnmounted() {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        mounter.leavesMountedOnFailure = true
        _ = read(FakeDisks(ventoySnapshot()), mounter)
        XCTAssertEqual(mounter.unmounts.count, 1)
    }

    func testUnmountsEvenWhenReadingFails() {
        let mounter = FakeMounter()
        mounter.config = nil   // mounted, but no grub.cfg
        XCTAssertNil(read(FakeDisks(ventoySnapshot()), mounter).reading.version)
        XCTAssertEqual(mounter.unmounts.count, 1)

        let garbage = FakeMounter()
        garbage.config = "\u{0}\u{1} not grub"
        XCTAssertNil(read(FakeDisks(ventoySnapshot()), garbage).reading.version)
        XCTAssertEqual(garbage.unmounts.count, 1)
    }

    func testUnmountFailureIsReportedAndKeepsTheMountRecorded() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        mounter.unmountFailures = -1
        let result = read(FakeDisks(ventoySnapshot()), mounter)
        XCTAssertEqual(result.reading, .unknown("cleanup failed"))
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        let container = directory.deletingLastPathComponent()
        XCTAssertEqual(result.leftoverMount, container, "the janitor works on the container")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                      "a folder that may still be a mount point is never removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))
    }

    func testAbandonedMountIsALeftoverAndRemovesNothing() throws {
        // The mount tool outlived SIGKILL: its mount may appear after the
        // reader has returned, so nothing is removed and the container is reported.
        let mounter = FakeMounter()
        mounter.config = grub
        mounter.abandons = true
        let result = read(FakeDisks(ventoySnapshot()), mounter)
        XCTAssertNil(result.reading.version)
        let directory = try XCTUnwrap(mounter.mounts.first?.1)
        let container = directory.deletingLastPathComponent()
        XCTAssertEqual(result.leftoverMount, container)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))
        XCTAssertTrue(mounter.unmounts.isEmpty, "nothing was mounted yet, so nothing to unmount")
    }

    func testAbandonedMountThatHadAlreadyAppearedIsUnmountedButStillALeftover() throws {
        let mounter = FakeMounter()
        mounter.abandons = true
        var reader = reader(disks: FakeDisks(ventoySnapshot()), mounter: mounter)
        reader.makeMountPoint = { container in
            let url = container.appendingPathComponent("m", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            mounter.markMounted(url)   // it appears while the tool is abandoned
            return url
        }
        let result = reader.readVersion(volumeURL: volume, expected: expected, ticket: activeTicket())
        XCTAssertNotNil(result.leftoverMount)
        XCTAssertEqual(mounter.unmounts.count, 1)
    }

    func testAlreadyMountedPartitionIsReadInPlace() throws {
        let existing = root.appendingPathComponent("VTOYEFI", isDirectory: true)
        try FileManager.default.createDirectory(at: existing.appendingPathComponent("grub"),
                                                withIntermediateDirectories: true)
        try grub.write(to: existing.appendingPathComponent("grub/grub.cfg"), atomically: true, encoding: .utf8)
        let mounter = FakeMounter()
        let result = read(FakeDisks(ventoySnapshot(mountPoint: existing)), mounter)
        XCTAssertEqual(result.reading.version, VentoyVersion("1.1.18"))
        XCTAssertTrue(mounter.mounts.isEmpty)
        XCTAssertTrue(mounter.unmounts.isEmpty)
    }

    func testReadsAtMostOneMebibyte() {
        let mounter = FakeMounter()
        mounter.config = grub
        var reader = reader(disks: FakeDisks(ventoySnapshot()), mounter: mounter)
        let limits = LimitRecorder()
        reader.readFile = { url, limit in
            limits.record(limit)
            return try? Data(contentsOf: url)
        }
        _ = reader.readVersion(volumeURL: volume, expected: expected, ticket: activeTicket())
        XCTAssertEqual(limits.values, [1 << 20])
    }

    // MARK: Cancellation tickets

    func testCancelledTicketDescribesAndMountsNothing() {
        let disks = FakeDisks(ventoySnapshot())
        let mounter = FakeMounter()
        mounter.config = grub
        let ticket = VentoyReadTicket()
        XCTAssertTrue(ticket.cancel(), "a queued ticket can be released at once")
        XCTAssertFalse(ticket.activate(), "and never starts")
        let result = reader(disks: disks, mounter: mounter).readVersion(volumeURL: volume, expected: expected,
                                                                        ticket: ticket)
        XCTAssertEqual(result.reading, .unknown(VentoyReadTicket.cancelledReason))
        XCTAssertEqual(disks.calls, 0)
        XCTAssertEqual(mounter.mountCount, 0)
    }

    func testTicketCancelledBeforeTheMountAttemptStopsIt() throws {
        let mounter = FakeMounter()
        mounter.config = grub
        let ticket = VentoyReadTicket()
        XCTAssertTrue(ticket.activate())
        var reader = reader(disks: FakeDisks(ventoySnapshot()), mounter: mounter)
        let base = root!
        // The cap lands after the folder is made, just before the mount.
        reader.makeDirectory = {
            let url = base.appendingPathComponent("mnt-late", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertFalse(ticket.cancel(), "an active read keeps its hold")
            return url
        }
        let result = reader.readVersion(volumeURL: volume, expected: expected, ticket: ticket)
        XCTAssertEqual(result.reading, .unknown(VentoyReadTicket.cancelledReason))
        XCTAssertEqual(mounter.mountCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        ticket.finish()
        XCTAssertTrue(ticket.cancel(), "a finished read holds nothing")
    }

    func testMBRAndGPTBothMountWithMountDashF() {
        // No `diskutil mount` fallback on either layout (DESIGN §21): the one
        // mount attempt is the injected mounter's `mount -F`.
        for content in ["0xEF", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI"] {
            let mounter = FakeMounter()
            mounter.config = grub
            let result = read(FakeDisks(ventoySnapshot(content: content)), mounter)
            XCTAssertEqual(result.reading.version, VentoyVersion("1.1.18"), content)
            XCTAssertEqual(mounter.mounts.map(\.0), ["/dev/disk9s2"], content)
        }
        let command = LivePartitionMounter.mountCommand(devicePath: "/dev/disk9s2",
                                                        directory: URL(fileURLWithPath: "/tmp/c/m"))
        XCTAssertEqual(command.tool, "/sbin/mount")
        XCTAssertEqual(command.arguments, ["-F", "-t", "msdos", "-o", "rdonly,nobrowse,nodev,nosuid,noexec",
                                           "/dev/disk9s2", "/tmp/c/m"])
        XCTAssertEqual(LivePartitionMounter.maximumMountAttempts, 1)
    }

    func testFailedMountIsUnknownOnGPTToo() {
        let mounter = FakeMounter()
        mounter.mountSucceeds = false
        let result = read(FakeDisks(ventoySnapshot(content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")), mounter)
        XCTAssertNil(result.reading.version)
        XCTAssertEqual(mounter.mountCount, 1, "no second attempt by another tool")
    }

    func testActiveReadBoundCoversEveryToolLimit() {
        // 1 mount attempt + 2 × 3 unmount steps, each 10 + 2 + 2 s, plus 8 s.
        XCTAssertEqual(LivePartitionMounter.toolBound, 14)
        XCTAssertEqual(VentoyVersionReader.activeReadBound, 106)
    }

    // MARK: Leftover mounts

    /// `<container>/m`.
    private func mountPoint(_ container: URL) -> URL { container.appendingPathComponent("m", isDirectory: true) }

    /// A container the way the reader makes it: 0700, with `m` inside.
    @discardableResult
    private func makeContainer(_ name: String, in parent: URL? = nil) throws -> URL {
        let container = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try makePrivateFolder(container)
        try makePrivateFolder(mountPoint(container))
        return container
    }

    func testJanitorUnmountsAndRemovesOnlyItsOwnFolders() throws {
        let mine = try makeContainer("isotope-vtoyefi-A")
        let mounted = try makeContainer("isotope-vtoyefi-B")
        let other = root.appendingPathComponent("something-else", isDirectory: true)
        try makePrivateFolder(other)
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(mounted))
        let janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        XCTAssertEqual(Set(janitor.leftovers()), [mine, mounted])
        XCTAssertEqual(janitor.cleanUpLeftovers(), [])
        XCTAssertEqual(mounter.unmounts, [mountPoint(mounted)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mounted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testJanitorCleansAContainerWhoseMountedRootReportsAnotherOwnerAndMode() throws {
        // While VTOYEFI is mounted, lstat on the mount point reports the FAT
        // root's synthesized owner and mode; only the container is vetted by them.
        let container = try makeContainer("isotope-vtoyefi-R")
        let point = mountPoint(container)
        let mounter = FakeMounter()
        mounter.markMounted(point)
        var janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        janitor.inspectEntry = { url in
            if url.standardizedFileURL == point.standardizedFileURL {
                return VentoyFolderEntry(isDirectory: true, isSymlink: false, ownerUID: 0, permissions: 0o755)
            }
            return VentoyMountJanitor.lstatEntry(url)
        }
        XCTAssertTrue(janitor.cleanUp(container))
        XCTAssertEqual(mounter.unmounts, [point])
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
    }

    func testJanitorRefusesASymlinkedContainer() throws {
        let target = try makeContainer("elsewhere")
        let link = root.appendingPathComponent("isotope-vtoyefi-LINK")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(link))
        mounter.markMounted(mountPoint(target))
        let janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        XCTAssertEqual(janitor.cleanUpLeftovers().map(\.path), [link.path])
        XCTAssertEqual(mounter.unmounts, [])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint(target).path))
    }

    func testJanitorRefusesAContainerWithTheWrongMode() throws {
        let container = root.appendingPathComponent("isotope-vtoyefi-P", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try makePrivateFolder(mountPoint(container))
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(container))
        XCTAssertFalse(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(container))
        XCTAssertEqual(mounter.unmounts, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint(container).path))
    }

    func testJanitorNeverEmptiesAFolder() throws {
        // A container with something in it is left exactly as it is.
        let container = root.appendingPathComponent("isotope-vtoyefi-C", isDirectory: true)
        try makePrivateFolder(container)
        try Data("x".utf8).write(to: container.appendingPathComponent("file"))
        let janitor = VentoyMountJanitor(mounter: FakeMounter(), temporaryDirectory: root)
        XCTAssertEqual(janitor.cleanUpLeftovers(), [container])
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("file").path))

        // So is a mount point with something in it (rmdir fails, nothing else is tried).
        let full = try makeContainer("isotope-vtoyefi-F")
        try Data("x".utf8).write(to: mountPoint(full).appendingPathComponent("file"))
        XCTAssertFalse(VentoyMountJanitor(mounter: FakeMounter(), temporaryDirectory: root).cleanUp(full))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint(full).appendingPathComponent("file").path))

        let stuck = try makeContainer("isotope-vtoyefi-D")
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(stuck))
        mounter.unmountFailures = -1
        XCTAssertFalse(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(stuck))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint(stuck).path))
    }

    func testJanitorLeavesAMountPointThatIsASymlinkAlone() throws {
        let container = root.appendingPathComponent("isotope-vtoyefi-S", isDirectory: true)
        try makePrivateFolder(container)
        let target = try makeContainer("elsewhere2")
        try FileManager.default.createSymbolicLink(at: mountPoint(container),
                                                   withDestinationURL: mountPoint(target))
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(container))
        XCTAssertFalse(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(container))
        XCTAssertEqual(mounter.unmounts, [])
    }

    func testJanitorLeavesAnUnrelatedMountAlone() throws {
        let folder = try makeContainer("isotope-vtoyefi-W")
        let point = mountPoint(folder)
        let cases: [(String, VentoyMountInfo)] = [
            ("writable", VentoyMountInfo(mountedOn: point.path, mountedFrom: "/dev/disk9s2",
                                         fileSystem: "msdos", isReadOnly: false)),
            ("not this path", VentoyMountInfo(mountedOn: "/Volumes/Data", mountedFrom: "/dev/disk9s2",
                                              fileSystem: "msdos", isReadOnly: true)),
            ("the container, not the mount point", VentoyMountInfo(mountedOn: folder.path,
                                                                    mountedFrom: "/dev/disk9s2",
                                                                    fileSystem: "msdos", isReadOnly: true)),
            ("not FAT", VentoyMountInfo(mountedOn: point.path, mountedFrom: "/dev/disk9s2",
                                        fileSystem: "apfs", isReadOnly: true)),
            ("not partition 2", VentoyMountInfo(mountedOn: point.path, mountedFrom: "/dev/disk9s1",
                                                fileSystem: "msdos", isReadOnly: true)),
            ("not a disk", VentoyMountInfo(mountedOn: point.path, mountedFrom: "map auto_home",
                                           fileSystem: "msdos", isReadOnly: true)),
        ]
        for (label, info) in cases {
            let mounter = FakeMounter()
            mounter.markMounted(point)
            mounter.info = { _ in info }
            XCTAssertFalse(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(folder), label)
            XCTAssertEqual(mounter.unmounts, [], label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: point.path), label)
        }
        // Our own mount, as FSKit reports it, is undone.
        let mounter = FakeMounter()
        mounter.markMounted(point)
        mounter.info = { _ in VentoyMountInfo(mountedOn: point.path, mountedFrom: "disk9s2",
                                              fileSystem: "msdos", isReadOnly: true) }
        XCTAssertTrue(VentoyMountJanitor(mounter: mounter, temporaryDirectory: root).cleanUp(folder))
        XCTAssertEqual(mounter.unmounts, [point])
    }

    func testJanitorLeavesAFolderItDoesNotOwnAlone() throws {
        let folder = try makeContainer("isotope-vtoyefi-O")
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(folder))
        var janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        janitor.currentUID = getuid() + 1
        XCTAssertFalse(janitor.cleanUp(folder))
        XCTAssertEqual(mounter.unmounts, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // Nor one outside the temporary directory.
        let nested = try makeContainer("isotope-vtoyefi-Q", in: root.appendingPathComponent("sub", isDirectory: true))
        XCTAssertFalse(VentoyMountJanitor(mounter: FakeMounter(), temporaryDirectory: root).cleanUp(nested))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testJanitorSkipsAMountWhoseDiskIsBusyAndReleasesAfterwards() throws {
        let busy = try makeContainer("isotope-vtoyefi-X")
        let free = try makeContainer("isotope-vtoyefi-Y")
        let mounter = FakeMounter()
        mounter.markMounted(mountPoint(busy))
        mounter.markMounted(mountPoint(free))
        mounter.info = { directory in
            let disk = directory.path.contains("isotope-vtoyefi-X") ? "disk5s2" : "disk9s2"
            return VentoyMountInfo(mountedOn: directory.path, mountedFrom: "/dev/\(disk)", fileSystem: "msdos",
                                   isReadOnly: true)
        }
        let events = GateEvents()
        var janitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        janitor.diskGate = { disk in
            events.record("reserve \(disk)")
            guard disk != "disk5" else { return nil }
            return { events.record("release \(disk)") }
        }
        XCTAssertFalse(janitor.cleanUp(busy))
        XCTAssertTrue(mounter.unmounts.isEmpty, "a busy disk is not touched")
        XCTAssertTrue(janitor.cleanUp(free))
        XCTAssertEqual(events.values, ["reserve disk5", "reserve disk9", "release disk9"])
    }

    func testPartitionTwoNames() {
        for name in ["/dev/disk4s2", "disk4s2", "/dev/disk12s2"] {
            XCTAssertTrue(VentoyMountJanitor.isPartitionTwo(name), name)
        }
        for name in ["/dev/disk4s1", "disk4s12", "/dev/disk4", "disks2", "/dev/diskXs2", "map -hosts"] {
            XCTAssertFalse(VentoyMountJanitor.isPartitionTwo(name), name)
        }
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

private final class GateEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
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

    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity,
                     ticket: VentoyReadTicket) -> VentoyProbeResult {
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
        await waitUntil { probe.calls.count == 1 }   // running; a copy queued earlier would skip it
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

    func testCapKeepsARunningReadsHoldUntilItReturns() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        store.ventoyVersionReadCap = 0.1
        store.ventoyVersionWaitLimit = 0.3
        let drive = try startRead(store)
        await waitUntil { probe.calls.count == 1 }   // running, maybe mounted
        await waitUntil { store.ventoyVersions[drive.id] != nil }
        XCTAssertEqual(store.ventoyVersions[drive.id], .unknown("Reading the Ventoy version took too long"))
        XCTAssertTrue(store.isReadingVentoyVersion(drive), "past the cap, a running read still holds the stick")
        XCTAssertFalse(store.canEject(drive))
        XCTAssertEqual(store.ventoyReadTickets.values.first?.isCancelled, true)

        // A wait that outlives the limit refuses instead of starting.
        let started = Date()
        let clear = await store.waitForVentoyVersionReads(driveID: drive.id)
        XCTAssertEqual(clear, .timedOut)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)

        // No second read starts next to the one still running.
        store.markDisconnected(volumeUUID: "UUID-A")
        XCTAssertTrue(store.isReadingVentoyVersion(drive), "an unplug does not drop a running read")
        store.markConnected(drive, info: info(urlA, uuid: "UUID-A"))
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertNil(store.ventoyVersionReads[drive.id])

        probe.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        XCTAssertNil(store.ventoyVersions[drive.id], "the late result belongs to no connect")
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertTrue(store.canEject(drive))
        let nowClear = await store.waitForVentoyVersionReads(driveID: drive.id)
        XCTAssertEqual(nowClear, .clear)
    }

    func testQueuedReadPastItsCapReleasesAndNeverMounts() async throws {
        // Read A runs and blocks the queue; read B waits behind it.
        let blocking = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let disksB = FakeDisks(ventoySnapshot(volumeUUID: "UUID-B"))
        let mounterB = FakeMounter()
        mounterB.config = "set VENTOY_VERSION=\"1.1.18\"\n"
        let mountRoot = root!
        var readerB = VentoyVersionReader(disks: disksB, mounter: mounterB)
        readerB.makeDirectory = {
            let url = mountRoot.appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let store = await makeStore(probe: blocking)
        store.ventoyVersionReader = RoutingProbe([urlA: blocking, urlB: readerB])
        store.ventoyVersionReadCap = 0.3
        let a = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: a.id)
        await waitUntil { blocking.calls.count == 1 }
        let b = try store.registerDrive(at: urlB)
        store.scanAndReconcile(driveID: b.id)
        XCTAssertTrue(store.isReadingVentoyVersion(b), "queued, it holds the stick")

        // B's cap passes while it is still queued: its hold goes at once.
        await waitUntil { !store.isReadingVentoyVersion(b) }
        XCTAssertTrue(store.isReadingVentoyVersion(a), "A is running and keeps its hold")

        // So a flash may start now...
        var flashed = ManagedDrive(volumeUUID: "FLASHED", displayName: "Stick", bookmark: Data(),
                                   capacityBytes: 16_000_000_000)
        flashed.kind = .flashed
        store.addDrive(flashed)
        store.drivesWithOperationsInFlight.insert(flashed.id)

        // ...and when the queue moves on, B never reaches its mount step.
        blocking.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        await drainVentoyQueue()
        XCTAssertEqual(mounterB.mountCount, 0)
        XCTAssertEqual(mounterB.identityChecks, 0)
        XCTAssertEqual(disksB.calls, 0, "nothing was even described")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("mnt-") }, [])
    }

    func testStartCheckSkipsAReadWhoseDriveGotBusyInTheQueue() async throws {
        let blocking = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let probeB = probe([urlB: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: blocking)
        store.ventoyVersionReader = RoutingProbe([urlA: blocking, urlB: probeB])
        let a = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: a.id)
        await waitUntil { blocking.calls.count == 1 }
        let b = try store.registerDrive(at: urlB)
        store.scanAndReconcile(driveID: b.id)
        XCTAssertNotNil(store.ventoyVersionReads[b.id])
        // A copy to B is queued while B's read waits; the read is skipped.
        store.drivesWithOperationsInFlight.insert(b.id)
        blocking.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        await drainVentoyQueue()
        XCTAssertTrue(probeB.calls.isEmpty)
        XCTAssertNil(store.ventoyVersions[b.id], "not read, so it is read later")

        store.drivesWithOperationsInFlight.remove(b.id)
        await waitUntil { store.ventoyVersions[b.id] != nil }
        XCTAssertEqual(probeB.calls.count, 1)
    }

    func testManualCopyIsRefusedWhenAReadOutlivesTheWaitLimit() async throws {
        let volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let probe = probe([volume: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe, volumes: [volume: info(volume, uuid: "UUID-V")])
        store.ventoyVersionWaitLimit = 0.2
        let writer = FakeDriveWriter()
        let engine = UpdateEngine(store: store, downloads: FakeISOProvider(behaviour: .failure(CocoaError(.fileNoSuchFile))),
                                  drives: writer)
        store.updateEngine = engine
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)
        await waitUntil { probe.calls.count == 1 }

        let source = try TestFiles.write(root.appendingPathComponent("notes.txt"), size: 4096)
        let file = try LocalFile(url: source)
        let request = UpdateRequest(driveID: drive.id, driveName: "VENTOY", assignmentID: UUID(),
                                    entryID: "local-file", channelID: "local", title: file.name,
                                    release: file.release, isLocalFile: true)
        await engine.enqueueManual(request, sourceFile: source, fileName: file.name)
        await engine.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(writer.accessBalance, 0, "the drive was not even opened")
        XCTAssertEqual(store.operations.first?.errorMessage?.contains(AppStore.ventoyReadStuck), true,
                       store.operations.first?.errorMessage ?? "no message")
        // It says nothing was changed, and is not the copy failing (5a).
        XCTAssertEqual(store.operations.first?.errorMessage?.hasPrefix("Nothing was changed"), true)
        XCTAssertEqual(store.operations.first?.errorMessage?.contains("The copy to the drive failed"), false)
        probe.release()
    }

    func testFlashCancelledWhileWaitingForAReadWritesNothing() async throws {
        let store = await makeStore(probe: probe([:]))
        let flashed = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade", bookmark: Data(),
                                   assignments: [Assignment(entryID: "arch", channelID: "default")],
                                   capacityBytes: 32 << 30, kind: .flashed,
                                   hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583,
                                                          serialNumber: "SERIAL-1"),
                                   lastBSDName: "disk4")
        store.addDrive(flashed)
        let iso = try TestFiles.write(root.appendingPathComponent("arch.iso"), size: 64 * 1024)
        let release = Release(version: VersionToken.parse("2026.08.01")!,
                              isoURL: URL(string: "https://example.com/arch.iso")!, fileName: "arch.iso",
                              sha256: nil, sizeBytes: 64 * 1024, checkedAt: Date())
        let io = FakeFlashDeviceIO(description: FlashDeviceDescription(bsdName: "disk4",
                                                                       displayName: "SanDisk Cruzer Blade",
                                                                       sizeBytes: 32 << 30))
        let engine = FlashEngine(store: store, downloads: FakeISOProvider(behaviour: .file(iso)), io: io,
                                 hashing: store.hashing)
        let token = UUID()
        store.ventoyProbes[token] = VentoyProbeHold(driveID: UUID(), volumeUUID: "UUID-OTHER", wholeDisk: "disk4")
        let request = FlashRequest(driveID: flashed.id, driveName: flashed.displayName,
                                   assignmentID: flashed.assignments[0].id, entryID: "arch", channelID: "default",
                                   title: "Arch Linux", release: release, bsdName: "disk4",
                                   deviceName: "SanDisk Cruzer Blade", verifyAfterWrite: false)
        await engine.enqueue(request)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await engine.cancel(operationID: request.id)
        store.finishVentoyVersionRead(VentoyProbeResult(.unknown("x")), driveID: UUID(), token: token)
        await engine.drain()
        XCTAssertEqual(io.describeCount, 0)
        XCTAssertTrue(io.written.isEmpty)
        XCTAssertEqual(store.operations.first?.phase, .cancelled)
    }

    func testEjectReservesTheDiskSoNoReadStarts() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: probe)
        store.attachedDevices = [device()]
        var flashed = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade", bookmark: Data(),
                                   capacityBytes: 32 << 30)
        flashed.kind = .flashed
        flashed.hardwareID = HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: "SERIAL-1")
        store.addDrive(flashed)
        let gate = EjectGate()
        store.flashedDiskEjector = { bsdName in
            gate.record(bsdName)
            while !gate.isOpen { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let drive = try store.registerDrive(at: urlA)
        store.ejectFlashedDrive(driveID: flashed.id)
        XCTAssertEqual(store.ventoyEjectReservations.count, 1)

        // A scan of the Ventoy volume on that same stick, mid-eject.
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertNil(store.ventoyVersionReads[drive.id])
        XCTAssertTrue(store.ventoyProbes.isEmpty)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(gate.ejected, ["disk4"])

        gate.open()
        await waitUntil { store.ventoyEjectReservations.isEmpty }
    }

    private func drainVentoyQueue() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            AppStore.ventoyVersionQueue.async { done.resume() }
        }
        // Let a landing scheduled from the queue run on the main actor.
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func testUnregisterDuringAReadStillTracksIt() async throws {
        let probe = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let store = await makeStore(probe: probe)
        let drive = try startRead(store)
        await waitUntil { probe.calls.count == 1 }   // running, not just queued
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
        await waitUntil { probe.calls.count == 1 }   // running, not just queued
        let started = Date()
        await store.drainVentoyVersionReads(timeout: 0.2)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.15)
        XCTAssertLessThan(waited, 1.5)
        XCTAssertEqual(store.ventoyProbes.count, 1)
    }

    func testQuitDrainsAFinishingReadAndUndoesItsLeftoverMount() async throws {
        let leftover = root.appendingPathComponent("isotope-vtoyefi-L", isDirectory: true)
        try makePrivateFolder(leftover)
        try makePrivateFolder(leftover.appendingPathComponent("m", isDirectory: true))
        let probe = probe([:], blocking: true)
        probe.set(VentoyProbeResult(.unknown("cleanup failed"), leftoverMount: leftover), for: urlA)
        let store = await makeStore(probe: probe)
        let mounter = StubMounter(mounted: [leftover.appendingPathComponent("m", isDirectory: true)])
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        let drive = try startRead(store)
        await waitUntil { probe.calls.count == 1 }
        Task { try? await Task.sleep(nanoseconds: 100_000_000); probe.release() }
        await store.drainVentoyVersionReads(timeout: 3)
        XCTAssertTrue(store.ventoyProbes.isEmpty)
        XCTAssertTrue(store.ventoyLeftoverMounts.isEmpty)
        XCTAssertTrue(store.ventoyStuckHolds.isEmpty, "a successful cleanup releases the hold")
        XCTAssertEqual(mounter.unmounted, [leftover.appendingPathComponent("m", isDirectory: true)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(store.ventoyVersions[drive.id], .unknown("cleanup failed"))
        XCTAssertTrue(store.canEject(try XCTUnwrap(store.drive(id: drive.id))), "Eject is not held forever")
    }

    func testQuitCancelsAQueuedReadSoItNeverStarts() async throws {
        let blocking = probe([urlA: .known(VentoyVersion("1.1.18")!)], blocking: true)
        let probeB = probe([urlB: .known(VentoyVersion("1.1.18")!)])
        let store = await makeStore(probe: blocking)
        store.ventoyVersionReader = RoutingProbe([urlA: blocking, urlB: probeB])
        let a = try store.registerDrive(at: urlA)
        store.scanAndReconcile(driveID: a.id)
        await waitUntil { blocking.calls.count == 1 }
        let b = try store.registerDrive(at: urlB)
        store.scanAndReconcile(driveID: b.id)
        await store.drainVentoyVersionReads(timeout: 0.1)
        XCTAssertFalse(store.isReadingVentoyVersion(b), "the queued read is dropped at once")
        XCTAssertTrue(store.isReadingVentoyVersion(a), "the running one is still accounted for")
        blocking.release()
        await waitUntil { store.ventoyProbes.isEmpty }
        await drainVentoyQueue()
        XCTAssertTrue(probeB.calls.isEmpty)
    }

    func testLaunchCleansUpLeftoverFolders() async throws {
        let leftover = root.appendingPathComponent("isotope-vtoyefi-M", isDirectory: true)
        let stuck = root.appendingPathComponent("isotope-vtoyefi-N", isDirectory: true)
        for url in [leftover, stuck] {
            try makePrivateFolder(url)
            try makePrivateFolder(url.appendingPathComponent("m", isDirectory: true))
        }
        let store = await makeStore(probe: probe([:]))
        let mounter = StubMounter(mounted: [leftover.appendingPathComponent("m", isDirectory: true),
                                            stuck.appendingPathComponent("m", isDirectory: true)],
                                  stuck: [stuck.appendingPathComponent("m", isDirectory: true)])
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        store.cleanUpLeftoverVentoyMounts()
        await waitUntil { store.ventoyLeftoverMounts == [stuck] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
    }

    // MARK: Unfinished mounts keep the device held (DESIGN §21)

    /// The stick `device()` describes, with the identity `ventoySnapshot` reports.
    private func matchingDevice() -> FlashDevice {
        var device = device()
        device.hardwareID = HardwareID(vendorID: 1, productID: 2, serialNumber: "S1")
        return device
    }

    private func disk4Snapshot(volumeUUID: String = "UUID-A") -> VentoyDiskSnapshot {
        ventoySnapshot(whole: "disk4", partitionWhole: "disk4", name: "disk4s2", dataPartition: "disk4s1",
                       volumeUUID: volumeUUID)
    }

    /// A real reader over fakes, with containers made the way production makes them.
    private func realReader(mounter: FakeMounter, volumeUUID: String = "UUID-A") -> VentoyVersionReader {
        var reader = VentoyVersionReader(disks: FakeDisks(disk4Snapshot(volumeUUID: volumeUUID)), mounter: mounter)
        let base = root!
        reader.makeDirectory = {
            let url = base.appendingPathComponent("isotope-vtoyefi-\(UUID().uuidString)", isDirectory: true)
            try? makePrivateFolder(url)
            return url
        }
        return reader
    }

    private struct UnfinishedFixture {
        var store: AppStore
        var drive: ManagedDrive
        var flashed: ManagedDrive
        var mounter: FakeMounter
        var container: URL
    }

    /// The drive at `urlA` and a flashed registration of the same stick, after
    /// a read whose mount tool was abandoned: the mount may appear later.
    private func abandonedFixture(abandons: Bool = true, unmountFails: Bool = false) async throws -> UnfinishedFixture {
        let mounter = FakeMounter()
        mounter.abandons = abandons
        mounter.config = "set VENTOY_VERSION=\"1.1.18\"\n"
        if unmountFails { mounter.unmountFailures = -1 }
        let store = await makeStore(probe: probe([:]))
        store.ventoyVersionReader = realReader(mounter: mounter)
        store.attachedDevices = [matchingDevice()]
        var flashed = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade", bookmark: Data(),
                                   assignments: [Assignment(entryID: "arch", channelID: "default")],
                                   capacityBytes: 32 << 30, kind: .flashed,
                                   hardwareID: HardwareID(vendorID: 1, productID: 2, serialNumber: "S1"),
                                   lastBSDName: "disk4")
        flashed.kind = .flashed
        store.addDrive(flashed)
        let drive = try startRead(store)
        await waitUntil { store.ventoyProbes.isEmpty && !store.ventoyStuckHolds.isEmpty }
        let container = try XCTUnwrap(store.ventoyStuckHolds.keys.first)
        return UnfinishedFixture(store: store, drive: drive, flashed: flashed, mounter: mounter,
                                 container: container)
    }

    func testAbandonedMountKeepsTheStickHeldForUpdatesFlashesAndDeletes() async throws {
        let fixture = try await abandonedFixture()
        let store = fixture.store
        // The mount appears only after the reader has returned.
        fixture.mounter.markMounted(fixture.container.appendingPathComponent("m", isDirectory: true))

        XCTAssertFalse(store.isReadingVentoyVersion(fixture.drive), "the read itself is over")
        XCTAssertTrue(store.isVentoyReadUnfinished(fixture.drive))
        XCTAssertTrue(store.isVentoyReadUnfinished(fixture.flashed), "the same stick, registered as flashed")
        XCTAssertTrue(store.isVentoyReadUnfinished(bsdName: "disk4"))
        XCTAssertFalse(store.isVentoyReadUnfinished(bsdName: "disk7"))
        XCTAssertEqual(store.ventoyLeftoverMounts, [fixture.container])
        XCTAssertEqual(store.deleteBlocker(fileName: "a.iso", on: fixture.drive), AppStore.ventoyReadUnfinished)
        XCTAssertThrowsError(try store.deleteISO(fileName: "a.iso", on: fixture.drive.id))
        let update = await store.waitForVentoyVersionReads(driveID: fixture.drive.id)
        XCTAssertEqual(update, .unfinished, "refused at once, not after the wait limit")
        let flash = await store.waitForVentoyVersionReads(driveID: fixture.flashed.id, bsdName: "disk4")
        XCTAssertEqual(flash, .unfinished)

        // A flash is refused, with the clear message, and writes nothing.
        let iso = try TestFiles.write(root.appendingPathComponent("arch.iso"), size: 64 * 1024)
        let release = Release(version: VersionToken.parse("2026.08.01")!,
                              isoURL: URL(string: "https://example.com/arch.iso")!, fileName: "arch.iso",
                              sha256: nil, sizeBytes: 64 * 1024, checkedAt: Date())
        let io = FakeFlashDeviceIO(description: FlashDeviceDescription(bsdName: "disk4",
                                                                       displayName: "SanDisk Cruzer Blade",
                                                                       sizeBytes: 32 << 30))
        let engine = FlashEngine(store: store, downloads: FakeISOProvider(behaviour: .file(iso)), io: io,
                                 hashing: store.hashing)
        let request = FlashRequest(driveID: fixture.flashed.id, driveName: fixture.flashed.displayName,
                                   assignmentID: fixture.flashed.assignments[0].id, entryID: "arch",
                                   channelID: "default", title: "Arch Linux", release: release,
                                   bsdName: "disk4", deviceName: "SanDisk Cruzer Blade", verifyAfterWrite: false)
        let started = Date()
        await engine.enqueue(request)
        await engine.drain()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "not the wait limit")
        XCTAssertEqual(io.describeCount, 0)
        XCTAssertEqual(io.unmountCount, 0)
        XCTAssertTrue(io.written.isEmpty)
        let message = try XCTUnwrap(store.operations.first?.errorMessage)
        XCTAssertTrue(message.contains(AppStore.ventoyReadUnfinished), message)
        XCTAssertTrue(message.hasPrefix("Nothing was written"), message)
    }

    func testAbandonedMountRefusesAManualCopy() async throws {
        let volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let mounter = FakeMounter()
        mounter.abandons = true
        let store = await makeStore(probe: probe([:]), volumes: [volume: info(volume, uuid: "UUID-V")])
        store.ventoyVersionReader = realReader(mounter: mounter, volumeUUID: "UUID-V")
        let writer = FakeDriveWriter()
        let engine = UpdateEngine(store: store, downloads: FakeISOProvider(behaviour: .failure(CocoaError(.fileNoSuchFile))),
                                  drives: writer)
        store.updateEngine = engine
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)
        await waitUntil { store.ventoyProbes.isEmpty && !store.ventoyStuckHolds.isEmpty }

        let source = try TestFiles.write(root.appendingPathComponent("notes.txt"), size: 4096)
        let file = try LocalFile(url: source)
        let request = UpdateRequest(driveID: drive.id, driveName: "VENTOY", assignmentID: UUID(),
                                    entryID: "local-file", channelID: "local", title: file.name,
                                    release: file.release, isLocalFile: true)
        await engine.enqueueManual(request, sourceFile: source, fileName: file.name)
        await engine.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(writer.accessBalance, 0, "the drive was not even opened")
        let message = try XCTUnwrap(store.operations.first?.errorMessage)
        XCTAssertTrue(message.contains(AppStore.ventoyReadUnfinished), message)
        XCTAssertTrue(message.hasPrefix("Nothing was changed"), message)
    }

    func testEjectStaysAllowedWhileAMountIsUnfinishedAndTheDiskGoingReleasesIt() async throws {
        let fixture = try await abandonedFixture()
        let store = fixture.store
        XCTAssertTrue(store.canEject(fixture.drive), "eject is the recovery path")
        XCTAssertTrue(store.canEject(fixture.flashed))
        let ejected = GateEvents()
        store.flashedDiskEjector = { bsdName in ejected.record(bsdName) }
        store.ejectFlashedDrive(driveID: fixture.flashed.id)
        await waitUntil { ejected.values == ["disk4"] }
        XCTAssertFalse(store.ventoyStuckHolds.isEmpty, "the eject itself does not drop the hold")

        // The whole disk disappears from the device list: the mount went with it.
        store.attachedDevices = []
        XCTAssertTrue(store.ventoyStuckHolds.isEmpty)
        XCTAssertFalse(store.isVentoyReadUnfinished(fixture.flashed))
        let wait = await store.waitForVentoyVersionReads(driveID: fixture.flashed.id, bsdName: "disk4")
        XCTAssertEqual(wait, .clear)
    }

    func testDisconnectReleasesAnUnfinishedMount() async throws {
        let fixture = try await abandonedFixture()
        let store = fixture.store
        XCTAssertTrue(store.isVentoyReadUnfinished(fixture.drive))
        store.markDisconnected(volumeUUID: "UUID-A")
        XCTAssertTrue(store.ventoyStuckHolds.isEmpty)
        XCTAssertFalse(store.isVentoyReadUnfinished(fixture.drive))
        // The container is still recorded for the quit and launch janitors.
        XCTAssertEqual(store.ventoyLeftoverMounts, [fixture.container])
    }

    func testFailedUnmountKeepsTheHoldUntilTheJanitorCleansItUp() async throws {
        let fixture = try await abandonedFixture(abandons: false, unmountFails: true)
        let store = fixture.store
        XCTAssertEqual(fixture.drive.id, fixture.drive.id)
        XCTAssertTrue(store.isVentoyReadUnfinished(fixture.drive), "a failed unmount keeps the hold")
        XCTAssertEqual(store.ventoyVersions[fixture.drive.id], .unknown("cleanup failed"))
        XCTAssertTrue(store.canEject(fixture.drive))
        let wait = await store.waitForVentoyVersionReads(driveID: fixture.drive.id)
        XCTAssertEqual(wait, .unfinished)

        // Quit: the janitor undoes it (the unmount works this time) and the hold goes.
        fixture.mounter.unmountFailures = 0
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: fixture.mounter, temporaryDirectory: root)
        await store.drainVentoyVersionReads(timeout: 3)
        XCTAssertTrue(store.ventoyLeftoverMounts.isEmpty)
        XCTAssertTrue(store.ventoyStuckHolds.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.container.path))
    }

    func testCancelEndsAWaitForAReadImmediately() async throws {
        let store = await makeStore(probe: probe([:]))
        let drive = try store.registerDrive(at: urlA)
        store.ventoyProbes[UUID()] = VentoyProbeHold(driveID: drive.id, volumeUUID: "UUID-A", wholeDisk: nil)
        let cancelled = CancelSwitch()
        Task { try? await Task.sleep(nanoseconds: 100_000_000); cancelled.set() }
        let started = Date()
        let wait = await store.waitForVentoyVersionReads(driveID: drive.id, isCancelled: { cancelled.isSet })
        XCTAssertEqual(wait, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "not the wait limit")
    }

    // MARK: Janitor and the disk it unmounts on

    func testLaunchJanitorSkipsADiskWithAnOperationInFlightAndReservesTheOthers() async throws {
        let container = root.appendingPathComponent("isotope-vtoyefi-G", isDirectory: true)
        let point = container.appendingPathComponent("m", isDirectory: true)
        try makePrivateFolder(container)
        try makePrivateFolder(point)
        let store = await makeStore(probe: probe([:]))
        store.attachedDevices = [device()]
        let mounter = StubMounter(mounted: [point])   // reports it as disk4s2
        let reservations = GateEvents()
        mounter.onUnmount = {
            let count = DispatchQueue.main.sync { MainActor.assumeIsolated { store.ventoyEjectReservations.count } }
            reservations.record("reserved: \(count)")
        }
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        let drive = try store.registerDrive(at: urlA)
        store.drivesWithOperationsInFlight.insert(drive.id)   // an update is writing to disk4

        store.cleanUpLeftoverVentoyMounts()
        await waitUntil { store.ventoyLeftoverMounts == [container] }
        XCTAssertTrue(mounter.unmounted.isEmpty, "nothing is unmounted under an operation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: point.path))
        XCTAssertTrue(store.ventoyEjectReservations.isEmpty)

        // Once the disk is idle, it is reserved around the unmount and released after.
        store.drivesWithOperationsInFlight.remove(drive.id)
        store.cleanUpLeftoverVentoyMounts()
        await waitUntil { !FileManager.default.fileExists(atPath: container.path) }
        XCTAssertEqual(mounter.unmounted, [point])
        XCTAssertEqual(reservations.values, ["reserved: 1"], "the disk was reserved as an eject does")
        await waitUntil { store.ventoyEjectReservations.isEmpty }
    }

    func testLaunchJanitorSkipsADiskThatIsBeingEjected() async throws {
        let container = root.appendingPathComponent("isotope-vtoyefi-H", isDirectory: true)
        let point = container.appendingPathComponent("m", isDirectory: true)
        try makePrivateFolder(container)
        try makePrivateFolder(point)
        let store = await makeStore(probe: probe([:]))
        let mounter = StubMounter(mounted: [point])
        store.ventoyMountJanitor = VentoyMountJanitor(mounter: mounter, temporaryDirectory: root)
        let eject = store.reserveForEject(wholeDisk: "disk4", volumeUUIDs: [])
        store.cleanUpLeftoverVentoyMounts()
        await waitUntil { store.ventoyLeftoverMounts == [container] }
        XCTAssertTrue(mounter.unmounted.isEmpty)
        store.releaseEjectReservation(eject)
    }
}

/// Mount state from a list, for the janitor.
private final class StubMounter: PartitionMounting, @unchecked Sendable {
    private let lock = NSLock()
    private var mounted: Set<URL>
    private let stuck: Set<URL>
    private var unmountedList: [URL] = []
    /// Runs inside `unmount`, on the janitor's thread.
    var onUnmount: (@Sendable () -> Void)?

    init(mounted: Set<URL>, stuck: Set<URL> = []) {
        self.mounted = mounted
        self.stuck = stuck
    }

    var unmounted: [URL] { lock.withLock { unmountedList } }

    func mountReadOnly(devicePath: String, at directory: URL,
                       isStillSameDevice: () -> Bool) -> VentoyMountOutcome { .failed }
    func isMounted(at directory: URL) -> Bool { lock.withLock { mounted.contains(directory) } }
    func mountInfo(at directory: URL) -> VentoyMountInfo? {
        guard isMounted(at: directory) else { return nil }
        return VentoyMountInfo(mountedOn: directory.path, mountedFrom: "disk4s2", fileSystem: "msdos",
                               isReadOnly: true)
    }
    func unmount(directory: URL) -> Bool {
        onUnmount?()
        return lock.withLock {
            guard !stuck.contains(directory) else { return false }
            unmountedList.append(directory)
            mounted.remove(directory)
            return true
        }
    }
}

/// A folder the way the reader makes its own: mode 0700.
func makePrivateFolder(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}

/// Sends each read to the probe for its volume.
final class RoutingProbe: VentoyVersionProbing, @unchecked Sendable {
    private let routes: [URL: VentoyVersionProbing]
    init(_ routes: [URL: VentoyVersionProbing]) { self.routes = routes }
    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity,
                     ticket: VentoyReadTicket) -> VentoyProbeResult {
        routes[volumeURL]?.readVersion(volumeURL: volumeURL, expected: expected, ticket: ticket)
            ?? VentoyProbeResult(.unknown("no route"))
    }
}

private final class CancelSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Holds a fake eject open until the test lets it finish.
private final class EjectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var names: [String] = []
    var isOpen: Bool { lock.withLock { opened } }
    var ejected: [String] { lock.withLock { names } }
    func open() { lock.withLock { opened = true } }
    func record(_ name: String) { lock.withLock { names.append(name) } }
}
