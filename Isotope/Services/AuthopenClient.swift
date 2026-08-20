import Darwin
import Foundation

/// Failures of the privileged open (DESIGN §9 step 4).
enum AuthopenError: LocalizedError, Equatable {
    /// The user dismissed the macOS admin prompt (authopen exits non-zero).
    case authorizationCancelled
    case toolMissing
    case invalidDevicePath(String)
    case spawnFailed(String)
    /// authopen exited successfully but sent no descriptor — should not happen.
    case noDescriptorReceived

    var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            return "Isotope was not authorised to write to the device. Nothing was changed — try again and approve the administrator prompt."
        case .toolMissing:
            return "macOS's /usr/libexec/authopen is missing, so Isotope cannot obtain write access to the device."
        case .invalidDevicePath(let path):
            return "“\(path)” is not a device Isotope can open. Reconnect the device and try again."
        case .spawnFailed(let message):
            return "Isotope could not ask macOS for write access to the device: \(message)"
        case .noDescriptorReceived:
            return "macOS authorised the write but handed Isotope no device handle. Try again."
        }
    }
}

/// Opens `/dev/rdiskN` with administrator authorisation, without a privileged
/// helper or any stored privilege (PRD F29, DESIGN §1 N3).
///
/// `/usr/libexec/authopen -stdoutpipe -o <flags> <path>` shows the standard
/// macOS admin prompt, opens the file itself, and passes the **open file
/// descriptor** back over its stdout — which therefore has to be a UNIX-domain
/// socket, because a descriptor travels as an `SCM_RIGHTS` control message.
/// Isotope creates a `socketpair`, hands one end to the child as stdout, and
/// reads the descriptor off the other end with `recvmsg`.
///
/// **Not unit-tested**: `open()` needs a real authorisation prompt and a real
/// device, so it is exercised only by the manual flash checklist. Everything
/// that *can* be tested without those — the argument vector and the control
/// message parsing — is a separate static function below, and
/// `receiveDescriptor(from:)` is covered by a socketpair test that passes an
/// ordinary file descriptor. Keep this split when changing anything here.
enum AuthopenClient {
    static let toolPath = "/usr/libexec/authopen"

    // MARK: - Testable pieces

    /// The argument vector. `-stdoutpipe` is what makes authopen send the
    /// descriptor instead of copying the file's bytes; `-o` takes the `open(2)`
    /// flags as a decimal number.
    static func arguments(devicePath: String, flags: Int32) -> [String] {
        ["-stdoutpipe", "-o", String(flags), devicePath]
    }

    /// Darwin aligns control messages on 4 bytes (`__DARWIN_ALIGN32`), not on
    /// `size_t` — getting this wrong reads the descriptor out of the padding.
    static func align32(_ value: Int) -> Int { (value + 3) & ~3 }

    /// `CMSG_SPACE(sizeof(int) * count)`.
    static func controlBufferSize(descriptorCount: Int = 1) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + align32(MemoryLayout<Int32>.size * descriptorCount)
    }

    /// `CMSG_LEN(sizeof(int) * count)`.
    static func controlMessageLength(descriptorCount: Int = 1) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + MemoryLayout<Int32>.size * descriptorCount
    }

    /// Reads the descriptor out of a received control buffer. Split from
    /// `recvmsg` so the parsing can be tested against a buffer built by hand as
    /// well as by the kernel.
    static func descriptor(inControlBuffer buffer: UnsafeRawBufferPointer, byteCount: Int) -> Int32? {
        let headerSize = MemoryLayout<cmsghdr>.size
        guard byteCount >= controlMessageLength(), buffer.count >= headerSize else { return nil }
        let header = buffer.loadUnaligned(as: cmsghdr.self)
        guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS,
              Int(header.cmsg_len) >= controlMessageLength() else { return nil }
        let offset = align32(headerSize)
        guard buffer.count >= offset + MemoryLayout<Int32>.size else { return nil }
        let descriptor = buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)
        return descriptor >= 0 ? descriptor : nil
    }

    /// Receives one `SCM_RIGHTS` descriptor from a UNIX-domain socket. Pure
    /// Darwin: no authopen involved, which is why the socketpair test can drive
    /// it end to end.
    static func receiveDescriptor(from socket: Int32) -> Int32? {
        var byte: UInt8 = 0
        var control = [UInt8](repeating: 0, count: controlBufferSize())
        return withUnsafeMutableBytes(of: &byte) { dataBuffer -> Int32? in
            control.withUnsafeMutableBytes { controlBuffer -> Int32? in
                var iov = iovec(iov_base: dataBuffer.baseAddress, iov_len: dataBuffer.count)
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int32? in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBuffer.baseAddress
                    message.msg_controllen = socklen_t(controlBuffer.count)
                    let received = recvmsg(socket, &message, 0)
                    guard received >= 0 else { return nil }
                    return descriptor(inControlBuffer: UnsafeRawBufferPointer(controlBuffer),
                                      byteCount: Int(message.msg_controllen))
                }
            }
        }
    }

    // MARK: - The real thing (manual integration only)

    /// Spawns authopen, shows the admin prompt, and returns the open descriptor.
    /// The caller owns the descriptor and must `close()` it.
    static func open(devicePath: String, flags: Int32) throws -> Int32 {
        guard devicePath.hasPrefix("/dev/"), FileManager.default.fileExists(atPath: devicePath) else {
            throw AuthopenError.invalidDevicePath(devicePath)
        }
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw AuthopenError.toolMissing
        }

        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw AuthopenError.spawnFailed(String(cString: strerror(errno)))
        }
        let local = pair[0]
        let remote = pair[1]
        defer { close(local) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments(devicePath: devicePath, flags: flags)
        // authopen writes the descriptor to its stdout, which must be the socket.
        process.standardOutput = FileHandle(fileDescriptor: remote, closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(remote)
            throw AuthopenError.spawnFailed(error.localizedDescription)
        }
        // The child owns its copy now; keeping ours open would hide its exit.
        close(remote)

        let descriptor = receiveDescriptor(from: local)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if let descriptor { close(descriptor) }
            // authopen exits non-zero both when the user cancels and when the
            // authorisation is denied; from here they are the same thing.
            throw AuthopenError.authorizationCancelled
        }
        guard let descriptor else { throw AuthopenError.noDescriptorReceived }
        return descriptor
    }
}
