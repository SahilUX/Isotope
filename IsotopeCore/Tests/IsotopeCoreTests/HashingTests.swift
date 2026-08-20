import XCTest
@testable import IsotopeCore

/// Core defines no hash implementation, so the protocol is exercised with a
/// trivial fake that records the byte stream it was fed.
private final class FakeHasher: StreamingHasher {
    private var bytes = Data()
    func update(_ data: Data) { bytes.append(data) }
    func finalizeHex() -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

private struct FakeHashing: Hashing {
    func makeHasher() -> StreamingHasher { FakeHasher() }
}

final class HashingTests: XCTestCase {
    func testStreamingFileHashSeesEveryByteInOrder() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("isotope-hash-\(UUID().uuidString).bin")
        let payload = Data((0..<(1 << 16)).map { UInt8($0 % 251) })
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let hashing = FakeHashing()
        // Chunk size below the file size proves the streaming loop concatenates correctly.
        let streamed = try hashing.sha256Hex(ofFileAt: url, chunkSize: 4096)
        XCTAssertEqual(streamed, hashing.sha256Hex(of: payload))
    }

    func testCancellationThrows() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("isotope-hash-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try FakeHashing().sha256Hex(ofFileAt: url, shouldContinue: { false })) { error in
            XCTAssertEqual(error as? HashingError, .cancelled)
        }
    }

    func testChecksumComparisonIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(checksumsMatch("ABCDEF", " abcdef\n"))
        XCTAssertFalse(checksumsMatch("abcdef", "abcde0"))
        XCTAssertFalse(checksumsMatch(nil, "abcdef"))
        XCTAssertFalse(checksumsMatch("abcdef", nil))
    }
}
