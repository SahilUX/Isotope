import Foundation

/// Streamed file copy with progress, cancellation and "the stick was pulled out"
/// detection (PRD F25, DESIGN §6).
///
/// `FileManager.copyItem` would be shorter but gives no progress and no way to
/// stop, and an unplugged volume does not fail a write that is already buffered
/// against an open descriptor — hence the explicit liveness check per chunk.
/// How often a write loop is allowed to disturb the UI.
///
/// The copy itself runs off the main actor, but every progress report hops back
/// on to it and invalidates the drive view. At one report per 4 MiB chunk a fast
/// stick produces dozens a second, and the main thread spends its life
/// redrawing a progress bar instead of answering the user — which is what a
/// spinning cursor during a copy actually was.
///
/// Ten a second is more than the eye resolves and a fraction of the cost.
final class ProgressThrottle: @unchecked Sendable {
    static let defaultInterval: TimeInterval = 0.1

    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastEmitted: Date?

    init(interval: TimeInterval = ProgressThrottle.defaultInterval) {
        self.interval = interval
    }

    /// True when this report should be forwarded. `force` is for the last one,
    /// which must always land so the bar finishes where it should.
    func shouldEmit(force: Bool = false, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !force else {
            lastEmitted = now
            return true
        }
        if let lastEmitted, now.timeIntervalSince(lastEmitted) < interval { return false }
        lastEmitted = now
        return true
    }
}

enum ChunkedCopy {
    enum Control: Equatable {
        case proceed
        case cancel
        /// The destination folder is gone: the drive was unplugged or unmounted.
        case driveGone
    }

    enum Failure: LocalizedError, Equatable {
        case cancelled
        case driveGone
        case io(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "The copy was cancelled."
            case .driveGone: return "The drive was disconnected during the copy."
            case .io(let message): return message
            }
        }
    }

    static let defaultChunkSize = 4 * 1024 * 1024

    /// Take the page cache out of the loop, in both directions.
    ///
    /// macOS absorbs writes into RAM and returns immediately, so a copy to a
    /// slow stick *looks* like it runs at 200 MB/s for the first few gigabytes
    /// and then stalls — the speed on screen is the speed of memory, the ETA is
    /// fiction, and the final `synchronize()` sits at 100% for minutes while the
    /// backlog drains. Measured on a Ventoy stick while Isotope claimed
    /// 202.6 MB/s: `iostat` had the device doing 10–17 MB/s.
    ///
    /// `F_NOCACHE` makes each write wait for the device, so the rate shown is
    /// the rate happening. On the read side it keeps an 8 GB ISO from evicting
    /// everything else from the cache on its way past. Total wall-clock is
    /// unchanged — the bytes were always going to take as long as they take —
    /// but what the user is told about it becomes true.
    ///
    /// Returns false if the descriptor refuses, which is not worth failing a
    /// copy over: it means the numbers are optimistic again, not that the data
    /// is at risk.
    @discardableResult
    static func bypassCache(_ descriptor: Int32) -> Bool {
        descriptor >= 0 && fcntl(descriptor, F_NOCACHE, 1) != -1
    }

    /// Copies `source` to `destination`, calling `control` and `progress` once
    /// per chunk. On cancellation or disconnection the partial file is removed.
    /// `willSynchronize` fires once the last byte has been written and the
    /// flush begins. Without it the UI sits at 100% saying "Copying" while the
    /// drive finishes, which reads as a hang — the one thing a progress display
    /// exists to prevent.
    static func run(from source: URL, to destination: URL,
                    chunkSize: Int = defaultChunkSize,
                    control: @Sendable () -> Control,
                    progress: @Sendable (Int64) -> Void,
                    willSynchronize: (@Sendable () -> Void)? = nil) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw Failure.io("Could not create “\(destination.lastPathComponent)” on the drive.")
        }
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
            output = try FileHandle(forWritingTo: destination)
        } catch {
            try? manager.removeItem(at: destination)
            throw Failure.io(error.localizedDescription)
        }
        // PRD F65: honest progress starts here.
        bypassCache(input.fileDescriptor)
        bypassCache(output.fileDescriptor)
        defer {
            try? input.close()
            try? output.close()
        }

        var written: Int64 = 0
        while true {
            switch control() {
            case .proceed: break
            case .cancel:
                try? output.close()
                try? manager.removeItem(at: destination)
                throw Failure.cancelled
            case .driveGone:
                try? output.close()
                try? manager.removeItem(at: destination)
                throw Failure.driveGone
            }
            let chunk: Data
            do {
                chunk = try input.read(upToCount: chunkSize) ?? Data()
            } catch {
                try? manager.removeItem(at: destination)
                throw Failure.io("The cached ISO could not be read: \(error.localizedDescription)")
            }
            if chunk.isEmpty { break }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                try? manager.removeItem(at: destination)
                // A full or vanished volume both surface here.
                throw control() == .driveGone
                    ? Failure.driveGone
                    : Failure.io("Writing to the drive failed: \(error.localizedDescription)")
            }
            written += Int64(chunk.count)
            progress(written)
        }
        willSynchronize?()
        do {
            try output.synchronize()
        } catch {
            try? manager.removeItem(at: destination)
            throw Failure.io("The copy could not be flushed to the drive: \(error.localizedDescription)")
        }
    }
}

/// Thread-safe flag the copy loop polls; set from the actor when the user
/// cancels or the drive disappears.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
