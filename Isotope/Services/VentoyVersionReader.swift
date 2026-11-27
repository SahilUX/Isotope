import DiskArbitration
import Foundation
import IsotopeCore

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
    /// Blocking (it may mount a partition); callers run it off the main actor.
    func readVersion(volumeURL: URL) -> VentoyVersionReading
}

/// Partition 2 of the disk a Ventoy data volume lives on, as DiskArbitration
/// describes it.
struct VentoyEFIPartitionInfo: Equatable, Sendable {
    var candidate: VentoyEFIPartitionCandidate
    /// Where it is already mounted, if anything has mounted it.
    var mountPoint: URL?
    var devicePath: String { "/dev/\(candidate.partitionBSDName)" }
}

/// The DiskArbitration half, injectable so tests never touch a real disk.
protocol VentoyDiskInspecting: Sendable {
    /// "disk4" for a volume mounted from /dev/disk4s1.
    func wholeDisk(forVolumeAt url: URL) -> String?
    /// `<wholeDisk>s2`, described, or nil when there is no such partition.
    func partitionTwo(ofWholeDisk wholeDisk: String) -> VentoyEFIPartitionInfo?
}

/// The mount half, injectable for the same reason.
protocol PartitionMounting: Sendable {
    /// Mounts `devicePath` read-only at `directory`. True only when the
    /// partition is now mounted there, read-only.
    func mountReadOnly(devicePath: String, at directory: URL) -> Bool
    /// Whether anything is mounted at `directory` right now.
    func isMounted(at directory: URL) -> Bool
    /// Unmounts whatever is at `directory`. True when nothing is mounted
    /// there afterwards.
    func unmount(directory: URL) -> Bool
}

struct VentoyVersionReader: VentoyVersionProbing {
    /// `grub.cfg` is about 100 KB; anything past this is not Ventoy's.
    static let maximumConfigBytes = 1 << 20
    static let configPath = "grub/grub.cfg"

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
            .appendingPathComponent("isotope-vtoyefi-\(UUID().uuidString)", isDirectory: true)
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
    var removeDirectory: @Sendable (URL) -> Void = { url in
        _ = url.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } }
    }

    func readVersion(volumeURL: URL) -> VentoyVersionReading {
        guard let whole = disks.wholeDisk(forVolumeAt: volumeURL) else {
            return .unknown("The drive's disk could not be identified")
        }
        guard let partition = disks.partitionTwo(ofWholeDisk: whole) else {
            return .unknown("The drive has no Ventoy EFI partition")
        }
        var candidate = partition.candidate
        candidate.dataWholeDisk = whole
        if let refusal = VentoyEFIPartitionRule.refusal(for: candidate) {
            return .unknown("Not read: \(refusal)")
        }
        if let mounted = partition.mountPoint {
            return parse(at: mounted)
        }
        guard let directory = makeDirectory() else {
            return .unknown("No temporary folder to mount the Ventoy EFI partition in")
        }
        defer { removeDirectory(directory) }
        let mounted = mounter.mountReadOnly(devicePath: partition.devicePath, at: directory)
        // Always unmount: after a successful mount, and also after a failed or
        // timed-out one that may still have left something mounted.
        defer {
            if mounted || mounter.isMounted(at: directory) { _ = mounter.unmount(directory: directory) }
        }
        guard mounted else { return .unknown("The Ventoy EFI partition could not be mounted read-only") }
        return parse(at: directory)
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
    func readVersion(volumeURL: URL) -> VentoyVersionReading { .unknown("Not read") }
}

// MARK: - Live DiskArbitration

struct LiveVentoyDiskInspector: VentoyDiskInspecting {
    func wholeDisk(forVolumeAt url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let whole = DADiskCopyWholeDisk(disk),
              let name = DADiskGetBSDName(whole) else { return nil }
        return String(cString: name)
    }

    func partitionTwo(ofWholeDisk wholeDisk: String) -> VentoyEFIPartitionInfo? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let partitionName = "\(wholeDisk)s2"
        guard let partition = DADiskCreateFromBSDName(kCFAllocatorDefault, session, partitionName),
              let description = DADiskCopyDescription(partition) as? [String: Any],
              let parent = DADiskCopyWholeDisk(partition),
              let parentName = DADiskGetBSDName(parent),
              let wholeDescription = DADiskCopyDescription(parent) as? [String: Any]
        else { return nil }
        let parentBSDName = String(cString: parentName)
        let device = DeviceEnumerator.makeDevice(
            bsdName: parentBSDName, description: wholeDescription, hardwareID: nil,
            bootDiskNames: DeviceEnumerator.bootDiskNames(session: session), volumes: [])
        let size = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let mountPoint = description[kDADiskDescriptionVolumePathKey as String] as? URL
        return VentoyEFIPartitionInfo(
            candidate: VentoyEFIPartitionCandidate(
                dataWholeDisk: wholeDisk, partitionBSDName: partitionName,
                partitionWholeDisk: parentBSDName, sizeBytes: size, content: content,
                disk: device.gateDescription()),
            mountPoint: mountPoint)
    }
}

// MARK: - Live mounting

/// `mount`/`umount`, with `diskutil` as the fallback for each, all as the
/// current user. No path here can write to the partition: the mount is
/// requested read-only, and a mount that comes back writable is undone at once.
struct LivePartitionMounter: PartitionMounting {
    static let timeout: TimeInterval = 10

    func mountReadOnly(devicePath: String, at directory: URL) -> Bool {
        let attempts: [(String, [String])] = [
            // FSKit's msdos module: works as a plain user where the kext
            // would need loading (DESIGN §21).
            ("/sbin/mount", ["-F", "-t", "msdos", "-o", "rdonly,nobrowse,nodev,nosuid,noexec",
                             devicePath, directory.path]),
            ("/usr/sbin/diskutil", ["mount", "readOnly", "nobrowse", "-mountPoint", directory.path,
                                    devicePath]),
        ]
        for (tool, arguments) in attempts {
            _ = ProcessRunner.run(tool, arguments, timeout: Self.timeout)
            switch Self.mountState(at: directory, devicePath: devicePath) {
            case .readOnly: return true
            case .writable:
                // Not what was asked for: never read from (or leave) it.
                _ = unmount(directory: directory)
                return false
            case .notMounted, .other:
                continue
            }
        }
        return false
    }

    func isMounted(at directory: URL) -> Bool {
        guard let parent = Self.statfsOf(directory.deletingLastPathComponent()),
              let own = Self.statfsOf(directory) else { return false }
        return parent.f_fsid.val.0 != own.f_fsid.val.0 || parent.f_fsid.val.1 != own.f_fsid.val.1
    }

    func unmount(directory: URL) -> Bool {
        _ = ProcessRunner.run("/sbin/umount", [directory.path], timeout: Self.timeout)
        if !isMounted(at: directory) { return true }
        _ = ProcessRunner.run("/usr/sbin/diskutil", ["unmount", directory.path], timeout: Self.timeout)
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

/// Runs a tool with a hard timeout. Output is discarded, so a full pipe can
/// never wedge it; the exit status is all the callers use.
enum ProcessRunner {
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        return process.terminationStatus
    }
}
