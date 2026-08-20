import Darwin
import Foundation
import IsotopeCore

/// Low-level failures of the raw-device path. `deviceVanished` is the one the
/// pipeline must treat specially: the stick was pulled out mid-write and is now
/// in an undefined state (DESIGN §9).
enum FlashIOError: LocalizedError, Equatable {
    case deviceVanished
    case io(String)

    var errorDescription: String? {
        switch self {
        case .deviceVanished: return "The device was disconnected."
        case .io(let message): return message
        }
    }

    /// `ENXIO`/`ENODEV`/`EIO` from a raw device all mean "the stick is gone".
    static func mapping(errno code: Int32) -> FlashIOError {
        switch code {
        case ENXIO, ENODEV, EIO, EBADF: return .deviceVanished
        default: return .io(String(cString: strerror(code)))
        }
    }
}

/// An open write handle on `/dev/rdiskN`.
protocol FlashDeviceWriting: AnyObject, Sendable {
    /// Writes one chunk. Raw devices only accept block-aligned writes, so a
    /// short final chunk is padded by the implementation.
    func write(_ chunk: Data) throws
    /// Flushes and closes. Called exactly once on the success path.
    func finish() throws
    /// Closes without flushing, on any failure path.
    func abort()
}

/// An open read handle on `/dev/rdiskN`, for read-back verification.
protocol FlashDeviceReading: AnyObject, Sendable {
    /// Returns up to `count` bytes; fewer only at the end of the device.
    func read(upTo count: Int) throws -> Data
    func close()
}

struct RemountedVolume: Sendable, Equatable {
    var volumeUUID: String?
    var volumeName: String?
}

/// Everything `FlashEngine` does to a physical device, behind one protocol so
/// the entire pipeline runs against a fake in tests — no hardware, no
/// authorisation, no root (DESIGN §9 "testing").
protocol FlashDeviceIO: Sendable {
    /// Fresh state for the flash-time gate re-check; nil when the device is gone.
    func describe(bsdName: String) async -> FlashDeviceDescription?
    func unmountDisk(bsdName: String) async throws
    /// Shows the macOS administrator prompt (once per flash, never stored).
    func openForWriting(bsdName: String) async throws -> FlashDeviceWriting
    func openForReading(bsdName: String) async throws -> FlashDeviceReading
    /// Mounts whatever the new image exposes, so the fresh volume UUID can be
    /// recorded (PRD F27). Never fatal: many images expose nothing macOS mounts.
    func remount(bsdName: String) async -> RemountedVolume
    func eject(bsdName: String) async throws
}

// MARK: - Live implementation

/// The real device path: `diskutil` for mount state, `authopen` for the
/// descriptors, `Darwin.write`/`read` for the bytes.
struct LiveFlashDeviceIO: FlashDeviceIO {
    /// Raw devices reject writes that are not a multiple of the block size, and
    /// an ISO's last chunk rarely is. 4096 covers both 512-byte and 4K sectors.
    static let blockSize = 4096

    private let enumerator: DeviceEnumerator

    init(enumerator: DeviceEnumerator) {
        self.enumerator = enumerator
    }

    func describe(bsdName: String) async -> FlashDeviceDescription? {
        enumerator.description(forBSDName: bsdName)
    }

    func unmountDisk(bsdName: String) async throws {
        // Plain `unmountDisk`, never `force`: if something is still using the
        // volume, the user should hear about it rather than lose the writes.
        try DiskUtil.run(["unmountDisk", "/dev/\(bsdName)"])
    }

    func openForWriting(bsdName: String) async throws -> FlashDeviceWriting {
        let path = DeviceEnumerator.rawDevicePath(bsdName: bsdName)
        let descriptor = try AuthopenClient.open(devicePath: path, flags: O_WRONLY)
        return RawDeviceWriter(descriptor: descriptor, blockSize: Self.blockSize)
    }

    func openForReading(bsdName: String) async throws -> FlashDeviceReading {
        let path = DeviceEnumerator.rawDevicePath(bsdName: bsdName)
        // A second authorisation rather than reusing the write descriptor:
        // re-opening proves the bytes really landed on the device.
        let descriptor = try AuthopenClient.open(devicePath: path, flags: O_RDONLY)
        return RawDeviceReader(descriptor: descriptor, blockSize: Self.blockSize)
    }

    func remount(bsdName: String) async -> RemountedVolume {
        // Best effort: plenty of images expose nothing macOS can mount, and
        // that is not a failure of the flash.
        _ = try? DiskUtil.run(["mountDisk", "/dev/\(bsdName)"])
        // Give the mount a moment to appear before reading its UUID back.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let volumes = enumerator.allWholeDisks().first { $0.bsdName == bsdName }
        return RemountedVolume(volumeUUID: volumes?.volumeUUIDs.first,
                               volumeName: volumes?.volumeNames.first)
    }

    func eject(bsdName: String) async throws {
        try DiskUtil.run(["eject", "/dev/\(bsdName)"])
    }
}

/// `diskutil` invocations (DESIGN §9 step 3). Kept tiny and separate so the
/// failure text the user sees is diskutil's own.
enum DiskUtil {
    static let path = "/usr/sbin/diskutil"

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw FlashIOError.io(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FlashIOError.io(text.isEmpty ? "diskutil \(arguments.joined(separator: " ")) failed."
                                               : text)
        }
        return text
    }
}

/// Writes to an authopen-provided descriptor. `@unchecked Sendable`: the
/// descriptor is only ever touched by one task at a time (the pipeline hands the
/// handle to a single write loop) and the lock makes that explicit.
private final class RawDeviceWriter: FlashDeviceWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let blockSize: Int

    init(descriptor: Int32, blockSize: Int) {
        self.descriptor = descriptor
        self.blockSize = blockSize
    }

    func write(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw FlashIOError.deviceVanished }
        var payload = chunk
        // Pad a short final chunk: the extra zero bytes land past the image on a
        // device that is by definition larger than it, and verification only
        // ever reads back the image's own length.
        let remainder = payload.count % blockSize
        if remainder != 0 { payload.append(Data(count: blockSize - remainder)) }
        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset),
                                           buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FlashIOError.mapping(errno: errno)
                }
                if written == 0 { throw FlashIOError.deviceVanished }
                offset += written
            }
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        if fsync(descriptor) != 0, errno != ENOTSUP {
            let failure = FlashIOError.mapping(errno: errno)
            close(descriptor)
            descriptor = -1
            throw failure
        }
        close(descriptor)
        descriptor = -1
    }

    func abort() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}

private final class RawDeviceReader: FlashDeviceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let blockSize: Int

    init(descriptor: Int32, blockSize: Int) {
        self.descriptor = descriptor
        self.blockSize = blockSize
    }

    func read(upTo count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw FlashIOError.deviceVanished }
        // Reads have to be block-aligned too; the caller truncates the tail.
        let aligned = max(blockSize, (count + blockSize - 1) / blockSize * blockSize)
        var buffer = [UInt8](repeating: 0, count: aligned)
        let read = buffer.withUnsafeMutableBytes { pointer -> Int in
            while true {
                let result = Darwin.read(descriptor, pointer.baseAddress, aligned)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        if read < 0 { throw FlashIOError.mapping(errno: errno) }
        return Data(buffer.prefix(min(read, count)))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
