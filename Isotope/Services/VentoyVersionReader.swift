import DiskArbitration
import Foundation
import IsotopeCore
import os

/// Reads which Ventoy release is installed on a connected Ventoy drive
/// (PRD F74, DESIGN §21).
///
/// Ventoy keeps its version on partition 2, the 32 MB VTOYEFI partition, in
/// `/grub/grub.cfg`. macOS never mounts that partition by itself, so this
/// mounts it read-only into a private temporary folder, reads at most 1 MiB of
/// one file, unmounts and removes the folder. It never writes, never asks for
/// administrator rights and never uses `authopen`. Every failure is
/// `.unknown(reason)`: the version is a nicety, and a read that cannot happen
/// cleanly does not happen.
protocol VentoyVersionProbing: Sendable {
    /// Blocking (it may mount a partition and wait on `mount`/`umount`); the
    /// store runs it on its own serial queue, never on the main actor or
    /// Swift's shared task threads.
    ///
    /// `ticket` is checked before anything is described or mounted and again
    /// immediately before every mount attempt: a cancelled ticket ends the
    /// read with `.unknown(VentoyReadTicket.cancelledReason)` and nothing
    /// mounted.
    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity,
                     ticket: VentoyReadTicket) -> VentoyProbeResult
    /// False for a reader that never reads: the store then starts no read
    /// and holds nothing.
    var isEnabled: Bool { get }
}

extension VentoyVersionProbing {
    var isEnabled: Bool { true }
}

/// One read's cancellation ticket (DESIGN §21), shared between the store on
/// the main actor and the read on `AppStore.ventoyVersionQueue`.
///
/// A read is queued until the store's start check (on the main actor, when
/// the work leaves the queue) activates it. Cancelling a queued ticket is
/// final: it can never become active, so nothing will be mounted and the
/// store may release the device at once. Cancelling an active ticket only
/// asks the read to stop before its next mount attempt; the store keeps the
/// device held until the read has actually returned and cleaned up.
final class VentoyReadTicket: @unchecked Sendable {
    enum State: Equatable, Sendable { case queued, active, finished }

    static let cancelledReason = "cancelled"

    private let lock = NSLock()
    private var stateValue: State = .queued
    private var cancelled = false

    init() {}

    var state: State { lock.withLock { stateValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Queued → active. False, and the read must not start, if it was
    /// cancelled first (or already ran).
    func activate() -> Bool {
        lock.withLock {
            guard stateValue == .queued, !cancelled else { return false }
            stateValue = .active
            return true
        }
    }

    /// Asks the read to stop. True when nothing can be mounted under this
    /// ticket any more (it never started, or it has finished), so the hold
    /// can go now; false while the read is active and may have a mount.
    @discardableResult
    func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return stateValue != .active
        }
    }

    func finish() { lock.withLock { stateValue = .finished } }
}

/// What the store knows about the drive before the read starts. The reader
/// refuses to mount anything unless the volume at `volumeURL` is still this
/// drive on this disk.
struct VentoyExpectedIdentity: Equatable, Sendable {
    /// The registered data volume's UUID.
    var volumeUUID: String
    /// The whole disk the device list has that volume on ("disk4"), if known.
    var wholeDisk: String?
    /// That whole disk's USB identity, if the device list has one.
    var hardwareID: HardwareID?
}

struct VentoyProbeResult: Equatable, Sendable {
    var reading: VentoyVersionReading
    /// A temporary mount the reader could not undo. The store keeps it and
    /// tries again at quit and at the next launch; a whole-disk eject
    /// unmounts it too.
    var leftoverMount: URL?

    init(_ reading: VentoyVersionReading, leftoverMount: URL? = nil) {
        self.reading = reading
        self.leftoverMount = leftoverMount
    }
}

/// Partition 2 of the disk a Ventoy data volume lives on, as DiskArbitration
/// describes it.
struct VentoyEFIPartitionInfo: Equatable, Sendable {
    var candidate: VentoyEFIPartitionCandidate
    /// Where it is already mounted, if anything has mounted it.
    var mountPoint: URL?
    var devicePath: String { "/dev/\(candidate.partitionBSDName)" }
}

/// A whole disk's DiskArbitration media identity. A BSD name alone is not an
/// identity: macOS hands "disk4" to the next disk that appears.
struct VentoyDiskIdentity: Equatable, Sendable {
    var bsdName: String
    var mediaUUID: String?
    /// The IOKit registry path of the media (`DAMediaPath`).
    var mediaPath: String?
    /// The IOKit registry path of the device (`DADevicePath`).
    var devicePath: String?
    var hardwareID: HardwareID?
}

/// One look at the drive as DiskArbitration describes it right now: the data
/// volume at the URL, its whole disk and that disk's partition 2.
struct VentoyDiskSnapshot: Equatable, Sendable {
    /// "disk4s1".
    var dataPartitionBSDName: String
    var dataVolumeUUID: String?
    var wholeDisk: VentoyDiskIdentity
    var efi: VentoyEFIPartitionInfo

    /// The same volume, disk and partition as `other`. Where partition 2 is
    /// mounted is left out: the reader's own mount changes it.
    func isSameDevice(as other: VentoyDiskSnapshot) -> Bool {
        dataPartitionBSDName == other.dataPartitionBSDName
            && dataVolumeUUID?.uppercased() == other.dataVolumeUUID?.uppercased()
            && wholeDisk == other.wholeDisk
            && efi.candidate == other.efi.candidate
    }
}

/// The DiskArbitration half, injectable so tests never touch a real disk.
protocol VentoyDiskInspecting: Sendable {
    /// A fresh description, or nil when the volume, its disk or partition 2
    /// cannot be described.
    func snapshot(forVolumeAt url: URL) -> VentoyDiskSnapshot?
}

/// What a mount attempt came to.
enum VentoyMountOutcome: Equatable, Sendable {
    /// Mounted read-only at the directory.
    case mounted
    case failed
    /// A re-check before an attempt found a different device; nothing was
    /// attempted after it.
    case identityChanged
}

/// The mount half, injectable for the same reason.
protocol PartitionMounting: Sendable {
    /// Mounts `devicePath` read-only at `directory`, calling `isStillSameDevice`
    /// immediately before each attempt and stopping if it says no. The
    /// `diskutil` fallback runs only when `allowsDiskutilFallback` (GPT).
    func mountReadOnly(devicePath: String, at directory: URL, allowsDiskutilFallback: Bool,
                       isStillSameDevice: () -> Bool) -> VentoyMountOutcome
    /// Whether anything is mounted at `directory` right now.
    func isMounted(at directory: URL) -> Bool
    /// What is mounted at `directory`, as `statfs` reports it, or nil.
    func mountInfo(at directory: URL) -> VentoyMountInfo?
    /// Unmounts whatever is at `directory`. True when nothing is mounted
    /// there afterwards.
    func unmount(directory: URL) -> Bool
}

/// A mount as `statfs` describes it (`f_mntonname`, `f_mntfromname`,
/// `f_fstypename`, `MNT_RDONLY`).
struct VentoyMountInfo: Equatable, Sendable {
    var mountedOn: String
    var mountedFrom: String
    var fileSystem: String
    var isReadOnly: Bool
}

/// A folder entry as `lstat` describes it: a symlink is never followed.
struct VentoyFolderEntry: Equatable, Sendable {
    var isDirectory: Bool
    var isSymlink: Bool
    var ownerUID: uid_t
    /// Permission bits only (`st_mode & 0o7777`).
    var permissions: UInt16
}

struct VentoyVersionReader: VentoyVersionProbing {
    /// `grub.cfg` is about 100 KB; anything past this is not Ventoy's.
    static let maximumConfigBytes = 1 << 20
    static let configPath = "grub/grub.cfg"
    /// Temporary mount folders are named with this prefix, so a launch can
    /// find any a crash left behind.
    static let directoryPrefix = "isotope-vtoyefi-"
    static let log = Logger(subsystem: "Isotope", category: "VentoyVersion")

    var disks: VentoyDiskInspecting = LiveVentoyDiskInspector()
    var mounter: PartitionMounting = LivePartitionMounter()
    /// (file, maximum bytes) → its first bytes, or nil.
    var readFile: @Sendable (URL, Int) -> Data? = { url, limit in
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }
    var makeDirectory: @Sendable () -> URL? = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(VentoyVersionReader.directoryPrefix)\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return url
        } catch {
            return nil
        }
    }
    /// `rmdir`, never a recursive delete: if an unmount silently failed, the
    /// folder is still a mount point and must not be emptied.
    var removeDirectory: @Sendable (URL) -> Void = { url in _ = VentoyMountJanitor.rmdir(url) }

    /// The longest an active read can take in the processes it runs (DESIGN
    /// §21): the mount attempts, an unmount of a mount that came back
    /// writable, and the unmount after the read, each tool bounded by
    /// `ProcessRunner`. DiskArbitration calls and the 1 MiB read are not
    /// process-bounded; a margin covers them on a healthy disk, and a store
    /// waiting longer than this treats the read as stuck.
    static var activeReadBound: TimeInterval {
        let tool = LivePartitionMounter.toolBound
        let mounts = Double(LivePartitionMounter.maximumMountAttempts) * tool
        let unmounts = 2 * Double(LivePartitionMounter.unmountSteps) * tool
        return mounts + unmounts + 8
    }

    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity,
                     ticket: VentoyReadTicket) -> VentoyProbeResult {
        let cancelled = VentoyProbeResult(.unknown(VentoyReadTicket.cancelledReason))
        guard !ticket.isCancelled else { return cancelled }
        guard let first = disks.snapshot(forVolumeAt: volumeURL) else {
            return VentoyProbeResult(.unknown("The drive's disk could not be identified"))
        }
        if let refusal = Self.identityRefusal(first, expected: expected) {
            return VentoyProbeResult(.unknown("Not read: \(refusal)"))
        }
        var candidate = first.efi.candidate
        candidate.dataWholeDisk = first.wholeDisk.bsdName
        candidate.dataPartitionBSDName = first.dataPartitionBSDName
        if let refusal = VentoyEFIPartitionRule.refusal(for: candidate) {
            return VentoyProbeResult(.unknown("Not read: \(refusal)"))
        }
        if let mounted = first.efi.mountPoint {
            return VentoyProbeResult(parse(at: mounted))
        }
        guard !ticket.isCancelled else { return cancelled }
        guard let directory = makeDirectory() else {
            return VentoyProbeResult(.unknown("No temporary folder to mount the Ventoy EFI partition in"))
        }
        let isStillSameDevice = {
            disks.snapshot(forVolumeAt: volumeURL).map { $0.isSameDevice(as: first) } ?? false
        }
        // Checked immediately before every mount attempt: the ticket first, so
        // a cancelled read never mounts, then the device.
        let mayMount = { !ticket.isCancelled && isStillSameDevice() }
        // diskutil's readOnly mount is only needed, and only used, on GPT
        // (DESIGN §21): it is unconfirmed whether its fsck pass could repair a
        // dirty FAT volume, and on MBR `mount -F` is the path that works.
        let outcome = mounter.mountReadOnly(
            devicePath: first.efi.devicePath, at: directory,
            allowsDiskutilFallback: VentoyEFIPartitionRule.isGPTEFIType(first.efi.candidate.content),
            isStillSameDevice: mayMount)
        let reading: VentoyVersionReading
        switch outcome {
        case .mounted:
            // Right after mounting: is it still the drive the store asked about?
            reading = isStillSameDevice()
                ? parse(at: directory)
                : .unknown("Not read: the drive changed while its Ventoy partition was being mounted")
        case .identityChanged:
            reading = ticket.isCancelled
                ? .unknown(VentoyReadTicket.cancelledReason)
                : .unknown("Not read: the drive changed before its Ventoy partition was mounted")
        case .failed:
            reading = .unknown("The Ventoy EFI partition could not be mounted read-only")
        }
        // Always unmount: after a successful mount, and also after a failed or
        // timed-out one that may still have left something mounted.
        if outcome == .mounted || mounter.isMounted(at: directory) {
            guard mounter.unmount(directory: directory) else {
                Self.log.error("Could not unmount the Ventoy EFI partition at \(directory.path, privacy: .public)")
                return VentoyProbeResult(.unknown("cleanup failed"), leftoverMount: directory)
            }
        }
        removeDirectory(directory)
        return VentoyProbeResult(reading)
    }

    /// Why the snapshot is not the drive the store expects, or nil.
    static func identityRefusal(_ snapshot: VentoyDiskSnapshot, expected: VentoyExpectedIdentity) -> String? {
        guard let uuid = snapshot.dataVolumeUUID,
              uuid.caseInsensitiveCompare(expected.volumeUUID) == .orderedSame else {
            return "the volume at this path is not the registered drive"
        }
        if let wholeDisk = expected.wholeDisk, wholeDisk != snapshot.wholeDisk.bsdName {
            return "the drive is not on the disk Isotope expected"
        }
        if let hardwareID = expected.hardwareID, snapshot.wholeDisk.hardwareID != hardwareID {
            return "the disk is not the USB device Isotope expected"
        }
        return nil
    }

    private func parse(at root: URL) -> VentoyVersionReading {
        let file = root.appendingPathComponent(Self.configPath)
        guard let data = readFile(file, Self.maximumConfigBytes) else {
            return .unknown("The Ventoy configuration could not be read")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let version = VentoyVersion.parse(grubConfig: text) else {
            return .unknown("The Ventoy configuration names no version")
        }
        return .known(version)
    }
}

/// Used under XCTest and wherever reading is not wanted: never touches a disk.
struct DisabledVentoyVersionReader: VentoyVersionProbing {
    var isEnabled: Bool { false }
    func readVersion(volumeURL: URL, expected: VentoyExpectedIdentity,
                     ticket: VentoyReadTicket) -> VentoyProbeResult {
        VentoyProbeResult(.unknown("Not read"))
    }
}

// MARK: - Leftover mounts

/// Finds and undoes temporary VTOYEFI mounts: the ones a read could not
/// unmount, and at launch any `isotope-vtoyefi-*` folder a crash left behind.
/// A folder is only ever `rmdir`ed, never deleted recursively.
///
/// It unmounts nothing it cannot prove is its own (DESIGN §21): the entry
/// must be a real directory (`lstat`, so a symlink is never followed) directly
/// in the temporary directory, owned by this user, mode 0700; and what is
/// mounted there must be mounted on exactly that path, read-only, FAT
/// (`msdos`), from a partition 2 (`diskNs2`). Anything else is left alone and
/// logged.
struct VentoyMountJanitor: Sendable {
    var mounter: PartitionMounting = LivePartitionMounter()
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    var removeDirectory: @Sendable (URL) -> Bool = { VentoyMountJanitor.rmdir($0) }
    var inspectEntry: @Sendable (URL) -> VentoyFolderEntry? = { VentoyMountJanitor.lstatEntry($0) }
    var currentUID: uid_t = getuid()

    /// `isotope-vtoyefi-*` entries in the temporary directory. `cleanUp`
    /// decides whether each one is really ours.
    func leftovers() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(VentoyVersionReader.directoryPrefix) }
            .map { temporaryDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Unmounts `directory` if our own mount is there, then removes the empty
    /// folder. True when the folder is gone.
    @discardableResult
    func cleanUp(_ directory: URL) -> Bool {
        if let refusal = folderRefusal(directory) {
            VentoyVersionReader.log.error("Left \(directory.path, privacy: .public) alone: \(refusal, privacy: .public)")
            return false
        }
        if mounter.isMounted(at: directory) {
            guard let info = mounter.mountInfo(at: directory) else {
                VentoyVersionReader.log.error("Left \(directory.path, privacy: .public) alone: its mount could not be described")
                return false
            }
            if let refusal = Self.mountRefusal(info, at: directory) {
                VentoyVersionReader.log.error("Left \(directory.path, privacy: .public) alone: \(refusal, privacy: .public)")
                return false
            }
            guard mounter.unmount(directory: directory) else {
                VentoyVersionReader.log.error("Leftover Ventoy mount at \(directory.path, privacy: .public) could not be unmounted")
                return false
            }
        }
        return removeDirectory(directory)
    }

    /// The folders that could not be cleaned up (or were not ours).
    @discardableResult
    func cleanUpLeftovers() -> [URL] {
        leftovers().filter { !cleanUp($0) }
    }

    /// Why `directory` is not one of our own temporary folders, or nil.
    func folderRefusal(_ directory: URL) -> String? {
        guard directory.lastPathComponent.hasPrefix(VentoyVersionReader.directoryPrefix),
              Self.canonicalPath(directory.deletingLastPathComponent().path)
                == Self.canonicalPath(temporaryDirectory.path) else {
            return "not an Isotope folder in the temporary directory"
        }
        guard let entry = inspectEntry(directory) else { return "it could not be described" }
        if entry.isSymlink { return "it is a symbolic link" }
        guard entry.isDirectory else { return "it is not a folder" }
        guard entry.ownerUID == currentUID else { return "it is owned by another user" }
        guard entry.permissions == 0o700 else { return "its permissions are not 0700" }
        return nil
    }

    /// Why the mount at `directory` is not a VTOYEFI mount of ours, or nil.
    static func mountRefusal(_ info: VentoyMountInfo, at directory: URL) -> String? {
        guard canonicalPath(info.mountedOn) == canonicalPath(directory.path) else {
            return "the folder is not itself a mount point"
        }
        guard info.isReadOnly else { return "the mount is writable" }
        guard info.fileSystem.caseInsensitiveCompare("msdos") == .orderedSame else {
            return "the mount is not FAT"
        }
        guard isPartitionTwo(info.mountedFrom) else { return "the mount is not a partition 2" }
        return nil
    }

    /// "/dev/disk4s2", "disk4s2" (FSKit reports either).
    static func isPartitionTwo(_ device: String) -> Bool {
        let name = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
        guard name.hasPrefix("disk"), name.hasSuffix("s2") else { return false }
        let number = name.dropFirst(4).dropLast(2)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `realpath`, so "/var/folders/…" and statfs's "/private/var/folders/…"
    /// compare equal. The leaf was already checked not to be a symlink.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func lstatEntry(_ url: URL) -> VentoyFolderEntry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return VentoyFolderEntry(isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK,
                                 ownerUID: info.st_uid, permissions: UInt16(info.st_mode & 0o7777))
    }

    static func rmdir(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in path.map { Darwin.rmdir($0) == 0 } ?? false }
    }
}

// MARK: - Live DiskArbitration

struct LiveVentoyDiskInspector: VentoyDiskInspecting {
    func snapshot(forVolumeAt url: URL) -> VentoyDiskSnapshot? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let data = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let dataName = DADiskGetBSDName(data),
              let dataDescription = DADiskCopyDescription(data) as? [String: Any],
              let whole = DADiskCopyWholeDisk(data),
              let wholeName = DADiskGetBSDName(whole),
              let wholeDescription = DADiskCopyDescription(whole) as? [String: Any]
        else { return nil }
        let wholeBSDName = String(cString: wholeName)
        let partitionName = "\(wholeBSDName)s2"
        guard let partition = DADiskCreateFromBSDName(kCFAllocatorDefault, session, partitionName),
              let description = DADiskCopyDescription(partition) as? [String: Any],
              let parent = DADiskCopyWholeDisk(partition),
              let parentName = DADiskGetBSDName(parent)
        else { return nil }
        let device = DeviceEnumerator.makeDevice(
            bsdName: wholeBSDName, description: wholeDescription, hardwareID: nil,
            bootDiskNames: DeviceEnumerator.bootDiskNames(session: session), volumes: [])
        let size = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let mountPoint = description[kDADiskDescriptionVolumePathKey as String] as? URL
        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
        let identity = VentoyDiskIdentity(
            bsdName: wholeBSDName,
            mediaUUID: Self.uuidString(wholeDescription[kDADiskDescriptionMediaUUIDKey as String]),
            mediaPath: wholeDescription[kDADiskDescriptionMediaPathKey as String] as? String,
            devicePath: wholeDescription[kDADiskDescriptionDevicePathKey as String] as? String,
            hardwareID: DeviceEnumerator.hardwareID(bsdName: wholeBSDName))
        return VentoyDiskSnapshot(
            dataPartitionBSDName: String(cString: dataName),
            dataVolumeUUID: Self.uuidString(dataDescription[kDADiskDescriptionVolumeUUIDKey as String]),
            wholeDisk: identity,
            efi: VentoyEFIPartitionInfo(
                candidate: VentoyEFIPartitionCandidate(
                    dataWholeDisk: wholeBSDName, partitionBSDName: partitionName,
                    partitionWholeDisk: String(cString: parentName), sizeBytes: size, content: content,
                    disk: device.gateDescription(),
                    dataPartitionBSDName: String(cString: dataName), volumeName: volumeName),
                mountPoint: mountPoint))
    }

    /// DiskArbitration hands UUIDs back as `CFUUID`.
    static func uuidString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
        let uuid = unsafeBitCast(object, to: CFUUID.self)
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }
}

// MARK: - Live mounting

/// `mount`/`umount`, with `diskutil` as the fallback for each, all as the
/// current user. No path here can write to the partition: the mount is
/// requested read-only, and a mount that comes back writable is undone at once.
struct LivePartitionMounter: PartitionMounting {
    static let timeout: TimeInterval = 10
    /// The longest one tool can hold a read: its timeout, then SIGTERM's and
    /// SIGKILL's grace periods, after which it is abandoned.
    static var toolBound: TimeInterval {
        timeout + ProcessRunner.terminateGrace + ProcessRunner.killGrace
    }
    /// `mount -F`, then `diskutil mount readOnly` on GPT only.
    static let maximumMountAttempts = 2
    /// `umount`, `umount`, `diskutil unmount force`.
    static let unmountSteps = 3

    func mountReadOnly(devicePath: String, at directory: URL, allowsDiskutilFallback: Bool,
                       isStillSameDevice: () -> Bool) -> VentoyMountOutcome {
        var attempts: [(String, [String])] = [
            // FSKit's msdos module: works as a plain user where the kext
            // would need loading (DESIGN §21).
            ("/sbin/mount", ["-F", "-t", "msdos", "-o", "rdonly,nobrowse,nodev,nosuid,noexec",
                             devicePath, directory.path]),
        ]
        if allowsDiskutilFallback {
            attempts.append(("/usr/sbin/diskutil", ["mount", "readOnly", "nobrowse", "-mountPoint",
                                                    directory.path, devicePath]))
        }
        for (tool, arguments) in attempts {
            guard isStillSameDevice() else { return .identityChanged }
            let outcome = ProcessRunner.run(tool, arguments, timeout: Self.timeout)
            switch Self.mountState(at: directory, devicePath: devicePath) {
            case .readOnly: return .mounted
            case .writable:
                // Not what was asked for: never read from (or leave) it.
                _ = unmount(directory: directory)
                return .failed
            case .notMounted, .other:
                // A tool that would not die even after SIGKILL is not run
                // again next to it; the caller still checks for a mount.
                if outcome == .abandoned { return .failed }
                continue
            }
        }
        return .failed
    }

    func mountInfo(at directory: URL) -> VentoyMountInfo? {
        guard isMounted(at: directory), var info = Self.statfsOf(directory) else { return nil }
        func string<T>(_ field: inout T, _ capacity: Int) -> String {
            withUnsafePointer(to: &field) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        }
        return VentoyMountInfo(mountedOn: string(&info.f_mntonname, Int(MAXPATHLEN)),
                               mountedFrom: string(&info.f_mntfromname, Int(MAXPATHLEN)),
                               fileSystem: string(&info.f_fstypename, Int(MFSTYPENAMELEN)),
                               isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    func isMounted(at directory: URL) -> Bool {
        guard let parent = Self.statfsOf(directory.deletingLastPathComponent()),
              let own = Self.statfsOf(directory) else { return false }
        return parent.f_fsid.val.0 != own.f_fsid.val.0 || parent.f_fsid.val.1 != own.f_fsid.val.1
    }

    /// `umount`, `umount` again, then `diskutil unmount force` (the mount is
    /// read-only, so forcing it loses nothing).
    func unmount(directory: URL) -> Bool {
        let steps: [(String, [String])] = [
            ("/sbin/umount", [directory.path]),
            ("/sbin/umount", [directory.path]),
            ("/usr/sbin/diskutil", ["unmount", "force", directory.path]),
        ]
        for (tool, arguments) in steps {
            _ = ProcessRunner.run(tool, arguments, timeout: Self.timeout)
            if !isMounted(at: directory) { return true }
        }
        return !isMounted(at: directory)
    }

    enum MountState { case notMounted, readOnly, writable, other }

    static func mountState(at directory: URL, devicePath: String) -> MountState {
        guard LivePartitionMounter().isMounted(at: directory), var info = statfsOf(directory) else {
            return .notMounted
        }
        let from = withUnsafePointer(to: &info.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let bsd = devicePath.split(separator: "/").last.map(String.init) ?? devicePath
        guard from == devicePath || from.hasSuffix("/\(bsd)") || from == bsd else { return .other }
        return info.f_flags & UInt32(MNT_RDONLY) != 0 ? .readOnly : .writable
    }

    private static func statfsOf(_ url: URL) -> statfs? {
        var buffer = statfs()
        guard statfs(url.path, &buffer) == 0 else { return nil }
        return buffer
    }
}

// MARK: - Bounded processes

/// What `ProcessRunner` needs from a child process; a fake stands in for it in
/// tests.
protocol ManagedProcess: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
}

final class LiveProcess: ManagedProcess {
    let process: Process
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    func terminate() { process.terminate() }
    func kill() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
}

/// Runs a tool with a hard time limit. Output is discarded, so a full pipe can
/// never wedge it. Every wait is bounded: past `timeout` the tool gets SIGTERM,
/// two seconds later SIGKILL, and if it has still not exited two seconds after
/// that it is abandoned (a process stuck in the kernel can outlive SIGKILL),
/// and the caller carries on.
enum ProcessRunner {
    enum Outcome: Equatable {
        case exited(Int32)
        case couldNotStart
        /// Ran past its timeout and was stopped.
        case timedOut
        /// Ran past its timeout and did not exit even after SIGKILL.
        case abandoned
    }

    static let terminateGrace: TimeInterval = 2
    static let killGrace: TimeInterval = 2

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .couldNotStart }
        return wait(for: LiveProcess(process), timeout: timeout)
    }

    static func wait(for process: ManagedProcess, timeout: TimeInterval,
                     terminateGrace: TimeInterval = terminateGrace,
                     killGrace: TimeInterval = killGrace,
                     pollInterval: TimeInterval = 0.02) -> Outcome {
        if waitForExit(process, within: timeout, pollInterval: pollInterval) {
            return .exited(process.terminationStatus)
        }
        process.terminate()
        if waitForExit(process, within: terminateGrace, pollInterval: pollInterval) { return .timedOut }
        process.kill()
        if waitForExit(process, within: killGrace, pollInterval: pollInterval) { return .timedOut }
        return .abandoned
    }

    private static func waitForExit(_ process: ManagedProcess, within interval: TimeInterval,
                                    pollInterval: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(interval)
        while process.isRunning {
            guard Date() < deadline else { return false }
            usleep(useconds_t(max(1_000, pollInterval * 1_000_000)))
        }
        return true
    }
}
