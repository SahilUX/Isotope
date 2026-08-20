import Darwin
import XCTest
@testable import Isotope

/// The testable half of `AuthopenClient` (DESIGN §9 step 4).
///
/// `AuthopenClient.open` itself is never called here: it needs a real device and
/// a real administrator prompt, and is covered by the manual flash checklist.
/// What *is* covered is everything the descriptor hand-off depends on — the
/// argument vector, the Darwin control-message arithmetic, and the `recvmsg`
/// path, driven over a socketpair with an ordinary temporary file's descriptor
/// standing in for the device.
final class AuthopenClientTests: XCTestCase {
    func testArgumentVector() {
        XCTAssertEqual(AuthopenClient.arguments(devicePath: "/dev/rdisk4", flags: O_WRONLY),
                       ["-stdoutpipe", "-o", "1", "/dev/rdisk4"])
        XCTAssertEqual(AuthopenClient.arguments(devicePath: "/dev/rdisk4", flags: O_RDONLY),
                       ["-stdoutpipe", "-o", "0", "/dev/rdisk4"])
    }

    /// Darwin aligns control messages on 4 bytes, not on `size_t`. Getting this
    /// wrong reads the descriptor out of the padding, so it is pinned here.
    func testControlMessageArithmeticMatchesDarwinAlignment() {
        XCTAssertEqual(AuthopenClient.align32(0), 0)
        XCTAssertEqual(AuthopenClient.align32(1), 4)
        XCTAssertEqual(AuthopenClient.align32(12), 12)
        XCTAssertEqual(AuthopenClient.align32(13), 16)
        XCTAssertEqual(MemoryLayout<cmsghdr>.size, 12)
        XCTAssertEqual(AuthopenClient.controlMessageLength(), 16)
        XCTAssertEqual(AuthopenClient.controlBufferSize(), 16)
    }

    func testGarbageControlBuffersYieldNoDescriptor() {
        let buffer = [UInt8](repeating: 0, count: AuthopenClient.controlBufferSize())
        buffer.withUnsafeBytes { raw in
            // All zeroes: wrong level, wrong type, zero length.
            XCTAssertNil(AuthopenClient.descriptor(inControlBuffer: raw, byteCount: raw.count))
            // A truthful buffer that the kernel said it did not fill.
            XCTAssertNil(AuthopenClient.descriptor(inControlBuffer: raw, byteCount: 0))
        }
    }

    /// End to end over a socketpair: one side sends a real descriptor the way
    /// authopen does, the other side is `AuthopenClient`'s own receiver.
    func testReceivesADescriptorSentAsSCMRights() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeAuthopenTest-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let payloadFD = open(path.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(payloadFD, 0)
        defer { close(payloadFD) }

        try sendDescriptor(payloadFD, over: pair[1])
        let received = try XCTUnwrap(AuthopenClient.receiveDescriptor(from: pair[0]))
        defer { close(received) }

        XCTAssertNotEqual(received, payloadFD)          // a genuinely new descriptor
        var buffer = [UInt8](repeating: 0, count: 16)
        let bytes = buffer.withUnsafeMutableBytes { read(received, $0.baseAddress, $0.count) }
        XCTAssertEqual(String(decoding: buffer.prefix(max(0, bytes)), as: UTF8.self), "payload")
    }

    /// The sender half, written the way `authopen -stdoutpipe` writes it.
    private func sendDescriptor(_ descriptor: Int32, over socket: Int32) throws {
        var byte: UInt8 = 0
        var control = [UInt8](repeating: 0, count: AuthopenClient.controlBufferSize())
        let sent: Int = withUnsafeMutableBytes(of: &byte) { dataBuffer in
            control.withUnsafeMutableBytes { controlBuffer -> Int in
                var header = cmsghdr()
                header.cmsg_len = socklen_t(AuthopenClient.controlMessageLength())
                header.cmsg_level = SOL_SOCKET
                header.cmsg_type = SCM_RIGHTS
                controlBuffer.storeBytes(of: header, as: cmsghdr.self)
                controlBuffer.storeBytes(of: descriptor,
                                         toByteOffset: AuthopenClient.align32(MemoryLayout<cmsghdr>.size),
                                         as: Int32.self)
                var iov = iovec(iov_base: dataBuffer.baseAddress, iov_len: dataBuffer.count)
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBuffer.baseAddress
                    message.msg_controllen = socklen_t(controlBuffer.count)
                    return sendmsg(socket, &message, 0)
                }
            }
        }
        XCTAssertGreaterThan(sent, 0, "sendmsg failed: \(String(cString: strerror(errno)))")
    }
}
