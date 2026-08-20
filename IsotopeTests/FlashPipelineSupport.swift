import Foundation
import IsotopeCore
@testable import Isotope

/// Fake raw-device layer for the flash pipeline. Nothing here touches a real
/// device, spawns `authopen` or needs an administrator — the whole point of
/// `FlashDeviceIO` being a protocol (DESIGN §9 "testing").
final class FakeFlashDeviceIO: FlashDeviceIO, @unchecked Sendable {
    enum OpenBehaviour {
        case succeed
        /// The user dismissed the macOS authorisation prompt.
        case authorizationCancelled
    }

    private let lock = NSLock()
    private var _description: FlashDeviceDescription?
    private var _openBehaviour: OpenBehaviour = .succeed
    /// Fails the write once this many bytes have landed (device pulled out).
    private var _vanishAfterBytes: Int64?
    /// Flips one byte of what is read back, so verification must fail.
    private var _corruptReadBack = false
    private var _remounted = RemountedVolume(volumeUUID: "NEW-VOLUME-UUID", volumeName: "UBUNTU")

    private(set) var written = Data()
    private(set) var unmountCount = 0
    private(set) var writeOpenCount = 0
    private(set) var readOpenCount = 0
    private(set) var ejectCount = 0
    private(set) var describeCount = 0
    private(set) var finished = false
    private(set) var aborted = false

    init(description: FlashDeviceDescription?) {
        _description = description
    }

    // MARK: Knobs

    func set(description: FlashDeviceDescription?) { lock.withLock { _description = description } }
    func set(openBehaviour: OpenBehaviour) { lock.withLock { _openBehaviour = openBehaviour } }
    func vanish(afterBytes: Int64) { lock.withLock { _vanishAfterBytes = afterBytes } }
    func corruptReadBack() { lock.withLock { _corruptReadBack = true } }
    func set(remounted: RemountedVolume) { lock.withLock { _remounted = remounted } }

    // MARK: FlashDeviceIO

    func describe(bsdName: String) async -> FlashDeviceDescription? {
        lock.withLock {
            describeCount += 1
            return _description
        }
    }

    func unmountDisk(bsdName: String) async throws {
        lock.withLock { unmountCount += 1 }
    }

    func openForWriting(bsdName: String) async throws -> FlashDeviceWriting {
        let behaviour: OpenBehaviour = lock.withLock {
            writeOpenCount += 1
            return _openBehaviour
        }
        if case .authorizationCancelled = behaviour { throw AuthopenError.authorizationCancelled }
        return Writer(io: self)
    }

    func openForReading(bsdName: String) async throws -> FlashDeviceReading {
        let behaviour: OpenBehaviour = lock.withLock {
            readOpenCount += 1
            return _openBehaviour
        }
        if case .authorizationCancelled = behaviour { throw AuthopenError.authorizationCancelled }
        return Reader(bytes: readBackBytes())
    }

    func remount(bsdName: String) async -> RemountedVolume { lock.withLock { _remounted } }

    func eject(bsdName: String) async throws { lock.withLock { ejectCount += 1 } }

    // MARK: Internals

    private func readBackBytes() -> Data {
        lock.withLock {
            guard _corruptReadBack, !written.isEmpty else { return written }
            var copy = written
            copy[0] = copy[0] &+ 1
            return copy
        }
    }

    /// Manual lock/unlock rather than `withLock`: the helper in
    /// `UpdatePipelineSupport` is non-throwing, and adding a throwing overload
    /// would make every existing call site ambiguous.
    fileprivate func append(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let limit = _vanishAfterBytes, Int64(written.count) + Int64(chunk.count) > limit {
            throw FlashIOError.deviceVanished
        }
        written.append(chunk)
    }

    fileprivate func markFinished() { lock.withLock { finished = true } }
    fileprivate func markAborted() { lock.withLock { aborted = true } }

    private final class Writer: FlashDeviceWriting, @unchecked Sendable {
        private let io: FakeFlashDeviceIO
        init(io: FakeFlashDeviceIO) { self.io = io }
        func write(_ chunk: Data) throws { try io.append(chunk) }
        func finish() throws { io.markFinished() }
        func abort() { io.markAborted() }
    }

    private final class Reader: FlashDeviceReading, @unchecked Sendable {
        private let lock = NSLock()
        private let bytes: Data
        private var offset = 0
        init(bytes: Data) { self.bytes = bytes }

        func read(upTo count: Int) throws -> Data {
            lock.withLock {
                let end = min(bytes.count, offset + count)
                guard end > offset else { return Data() }
                let slice = bytes[offset..<end]
                offset = end
                return Data(slice)
            }
        }

        func close() {}
    }
}
