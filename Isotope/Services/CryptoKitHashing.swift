import CryptoKit
import Foundation
import IsotopeCore

/// macOS implementation of the core `Hashing` abstraction. Incremental so that
/// multi-gigabyte ISOs are never held in memory (DESIGN §4.4).
struct CryptoKitHashing: Hashing {
    func makeHasher() -> StreamingHasher { CryptoKitStreamingHasher() }
}

private final class CryptoKitStreamingHasher: StreamingHasher {
    private var hasher = SHA256()

    func update(_ data: Data) {
        hasher.update(data: data)
    }

    func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
