import Foundation
import IsotopeCore
@testable import Isotope

// MARK: - Fake drive

/// Maps a fake bookmark (the volume path, UTF-8) onto a real temporary
/// directory, so the copy under test runs against a real filesystem while the
/// bookmark/volume metadata stays under the test's control.
final class FakeDriveWriter: DriveWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _availableBytes: Int64
    private var _isReadOnly: Bool
    private var _refreshedBookmark: Data?
    private var _resolveError: Error?
    private(set) var accessBalance = 0

    init(availableBytes: Int64 = 64 << 30, isReadOnly: Bool = false) {
        self._availableBytes = availableBytes
        self._isReadOnly = isReadOnly
    }

    var availableBytes: Int64 {
        get { lock.withLock { _availableBytes } }
        set { lock.withLock { _availableBytes = newValue } }
    }

    var isReadOnly: Bool {
        get { lock.withLock { _isReadOnly } }
        set { lock.withLock { _isReadOnly = newValue } }
    }

    var refreshedBookmark: Data? {
        get { lock.withLock { _refreshedBookmark } }
        set { lock.withLock { _refreshedBookmark = newValue } }
    }

    var resolveError: Error? {
        get { lock.withLock { _resolveError } }
        set { lock.withLock { _resolveError = newValue } }
    }

    func resolveVolume(bookmark: Data) throws -> ResolvedVolume {
        if let error = resolveError { throw error }
        let path = String(decoding: bookmark, as: UTF8.self)
        return ResolvedVolume(url: URL(fileURLWithPath: path, isDirectory: true),
                              refreshedBookmark: refreshedBookmark)
    }

    func volumeInfo(at url: URL) throws -> VolumeInfo {
        VolumeInfo(url: url, volumeUUID: "FAKE-UUID", name: url.lastPathComponent,
                   capacityBytes: 64 << 30, availableBytes: availableBytes,
                   isReadOnly: isReadOnly, isRemovable: true)
    }

    func beginAccess(_ url: URL) -> Bool {
        lock.withLock { accessBalance += 1 }
        return true
    }

    func endAccess(_ url: URL) {
        lock.withLock { accessBalance -= 1 }
    }
}

// MARK: - Fake download provider

/// Stands in for `DownloadManager`: hands back a file that already exists on
/// local disk, or throws whatever the test wants the download to fail with.
final class FakeISOProvider: ISOProviding, @unchecked Sendable {
    enum Behaviour {
        case file(URL)
        case failure(Error)
    }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private var _requests: [ISORequest] = []
    private var _endedKeys: [String] = []
    /// PRD F47: keys the engine asked to have deleted from the cache outright.
    private var _discardedKeys: [String] = []
    private var _pausedKeys: [String] = []
    private var _cancelledKeys: [String] = []
    /// Runs just before the file is handed back — the seam a test uses to make
    /// the world change mid-operation.
    var beforeReturn: (@Sendable () -> Void)?

    init(behaviour: Behaviour) { self.behaviour = behaviour }

    func set(_ behaviour: Behaviour) { lock.withLock { self.behaviour = behaviour } }

    var requests: [ISORequest] { lock.withLock { _requests } }
    var endedKeys: [String] { lock.withLock { _endedKeys } }
    var discardedKeys: [String] { lock.withLock { _discardedKeys } }
    var pausedKeys: [String] { lock.withLock { _pausedKeys } }
    var cancelledKeys: [String] { lock.withLock { _cancelledKeys } }

    func ensureLocalISO(_ request: ISORequest,
                        progress: @escaping @Sendable (DownloadStage, TransferProgress) -> Void)
        async throws -> LocalISO {
        let behaviour: Behaviour = lock.withLock {
            _requests.append(request)
            return self.behaviour
        }
        beforeReturn?()
        switch behaviour {
        case .failure(let error):
            throw error
        case .file(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            progress(.downloading, TransferProgress(completedBytes: size, totalBytes: size))
            return LocalISO(url: url, fileName: request.isoFileName,
                            sizeBytes: size, cacheKey: request.cacheKey)
        }
    }

    @discardableResult
    func endUse(cacheKey: String, discard: Bool) async -> Int64 {
        lock.withLock {
            _endedKeys.append(cacheKey)
            if discard { _discardedKeys.append(cacheKey) }
        }
        return discard ? 1_234 : 0
    }
    func pause(cacheKey: String) async { lock.withLock { _pausedKeys.append(cacheKey) } }
    func resume(cacheKey: String) async {}
    func cancel(cacheKey: String) async { lock.withLock { _cancelledKeys.append(cacheKey) } }
}

// MARK: - Helpers

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

enum TestFiles {
    /// A file of `size` bytes of repeatable content — big enough that a chunked
    /// copy really loops, small enough to stay instant.
    @discardableResult
    static func write(_ url: URL, size: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(count: size)
        for index in stride(from: 0, to: size, by: 977) { data[index] = UInt8(index % 251) }
        try data.write(to: url)
        return url
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
    }
}
