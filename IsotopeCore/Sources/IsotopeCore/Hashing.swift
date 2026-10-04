import Foundation

/// Streaming SHA-256 abstraction. Core stays free of CryptoKit so the same code
/// runs on Linux with swift-crypto; the macOS app injects a CryptoKit-backed
/// implementation. Files are multi-gigabyte, so the interface is incremental —
/// never load an ISO into memory.
public protocol StreamingHasher: AnyObject {
    func update(_ data: Data)
    /// Lowercase hex digest; the hasher must not be reused afterwards.
    func finalizeHex() -> String
}

public protocol Hashing: Sendable {
    func makeHasher() -> StreamingHasher
}

public extension Hashing {
    /// Hashes a file in `chunkSize` slices without mapping the whole file.
    /// `progress` receives the running byte count, so verification can show a
    /// determinate bar rather than a bare spinner (DESIGN §5).
    func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20,
                   shouldContinue: () -> Bool = { true },
                   progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let hasher = makeHasher()
        var read: Int64 = 0
        while true {
            guard shouldContinue() else { throw HashingError.cancelled }
            let count = try withChunkScope { () throws -> Int in
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                hasher.update(chunk)
                return chunk.count
            }
            if count == 0 { break }
            read += Int64(count)
            progress(read)
        }
        return hasher.finalizeHex()
    }

    func sha256Hex(of data: Data) -> String {
        let hasher = makeHasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }
}

public enum HashingError: Error, Equatable {
    case cancelled
}

/// Case-insensitive, whitespace-tolerant checksum comparison.
public func checksumsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
