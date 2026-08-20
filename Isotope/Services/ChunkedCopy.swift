import Foundation

/// Streamed file copy with progress, cancellation and "the stick was pulled out"
/// detection (PRD F25, DESIGN §6).
///
/// `FileManager.copyItem` would be shorter but gives no progress and no way to
/// stop, and an unplugged volume does not fail a write that is already buffered
/// against an open descriptor — hence the explicit liveness check per chunk.
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

    /// Copies `source` to `destination`, calling `control` and `progress` once
    /// per chunk. On cancellation or disconnection the partial file is removed.
    static func run(from source: URL, to destination: URL,
                    chunkSize: Int = defaultChunkSize,
                    control: @Sendable () -> Control,
                    progress: @Sendable (Int64) -> Void) throws {
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
