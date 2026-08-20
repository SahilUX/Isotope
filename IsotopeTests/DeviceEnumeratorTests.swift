import DiskArbitration
import IsotopeCore
import XCTest
@testable import Isotope

/// The separable half of `DeviceEnumerator`: turning a DiskArbitration
/// description into a `FlashDevice`, and deriving whole-disk names from device
/// nodes. No device is touched, and nothing here enumerates real hardware.
final class DeviceEnumeratorTests: XCTestCase {
    // MARK: - Device nodes

    func testWholeDiskNameFromEveryShapeOfDeviceNode() {
        let cases: [(String, String?)] = [
            ("/dev/disk4", "disk4"),
            ("/dev/disk4s1", "disk4"),
            ("/dev/rdisk4s1s2", "disk4"),      // APFS synthesised volume
            ("disk12s3", "disk12"),
            ("/dev/disk0s2", "disk0"),
            ("map -hosts", nil),               // network mount
            ("/dev/diskX", nil),
            ("", nil),
        ]
        for (node, expected) in cases {
            XCTAssertEqual(DeviceEnumerator.wholeDiskName(forDeviceNode: node), expected, node)
        }
    }

    func testRawDevicePathIsTheCharacterDevice() {
        XCTAssertEqual(DeviceEnumerator.rawDevicePath(bsdName: "disk4"), "/dev/rdisk4")
        // Idempotent if a caller ever passes the raw name already.
        XCTAssertEqual(DeviceEnumerator.rawDevicePath(bsdName: "rdisk4"), "/dev/rdisk4")
    }

    func testDisplayNameFallsBackWhenVendorAndModelAreBlank() {
        XCTAssertEqual(DeviceEnumerator.displayName(vendor: " SanDisk ", model: "Cruzer Blade ",
                                                    bsdName: "disk4"),
                       "SanDisk Cruzer Blade")
        XCTAssertEqual(DeviceEnumerator.displayName(vendor: nil, model: "Ultra", bsdName: "disk4"),
                       "Ultra")
        XCTAssertEqual(DeviceEnumerator.displayName(vendor: "  ", model: nil, bsdName: "disk4"),
                       "disk4")
    }

    func testVolumesAreGroupedByTheirWholeDisk() {
        let volumes = [
            DeviceEnumerator.MountedVolume(name: "Macintosh HD", uuid: "A", deviceNode: "/dev/disk3s1s1"),
            DeviceEnumerator.MountedVolume(name: "VENTOY", uuid: "B", deviceNode: "/dev/disk4s1"),
            DeviceEnumerator.MountedVolume(name: "VTOYEFI", uuid: "C", deviceNode: "/dev/disk4s2"),
            DeviceEnumerator.MountedVolume(name: "Server", uuid: nil, deviceNode: "//nas/share"),
        ]
        let grouped = DeviceEnumerator.groupByWholeDisk(volumes)
        XCTAssertEqual(grouped["disk4"]?.compactMap(\.name), ["VENTOY", "VTOYEFI"])
        XCTAssertEqual(grouped["disk3"]?.count, 1)
        XCTAssertNil(grouped[""])                       // the network mount is dropped
    }

    // MARK: - Description → FlashDevice

    private func description(internalDevice: Bool = false, removable: Bool = true,
                             ejectable: Bool = false, protocolName: String = "USB",
                             whole: Bool = true, size: Int64 = 32 << 30) -> [String: Any] {
        [
            kDADiskDescriptionDeviceVendorKey as String: "SanDisk ",
            kDADiskDescriptionDeviceModelKey as String: "Cruzer Blade",
            kDADiskDescriptionDeviceInternalKey as String: internalDevice,
            kDADiskDescriptionMediaRemovableKey as String: removable,
            kDADiskDescriptionMediaEjectableKey as String: ejectable,
            kDADiskDescriptionDeviceProtocolKey as String: protocolName,
            kDADiskDescriptionMediaWholeKey as String: whole,
            kDADiskDescriptionMediaSizeKey as String: NSNumber(value: size),
        ]
    }

    func testAnExternalUSBStickBecomesAnEligibleDevice() {
        let device = DeviceEnumerator.makeDevice(
            bsdName: "disk4", description: description(),
            hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: "S1"),
            bootDiskNames: ["disk3"],
            volumes: [DeviceEnumerator.MountedVolume(name: "UNTITLED", uuid: "VOL-1",
                                                     deviceNode: "/dev/disk4s1")])

        XCTAssertEqual(device.displayName, "SanDisk Cruzer Blade")
        XCTAssertEqual(device.sizeBytes, 32 << 30)
        XCTAssertTrue(device.isExternal)
        XCTAssertTrue(device.isUSB)
        XCTAssertTrue(device.isRemovableOrEjectable)
        XCTAssertFalse(device.isBootDisk)
        XCTAssertEqual(device.volumeNames, ["UNTITLED"])
        XCTAssertEqual(device.volumeUUIDs, ["VOL-1"])
        XCTAssertEqual(device.blockDevicePath, "/dev/disk4")
        XCTAssertEqual(device.rawDevicePath, "/dev/rdisk4")
        XCTAssertTrue(device.isEligibleForRegistration)
    }

    func testTheBootDiskAndInternalDisksAreNeverEligible() {
        let boot = DeviceEnumerator.makeDevice(bsdName: "disk3", description: description(),
                                               hardwareID: nil, bootDiskNames: ["disk3"], volumes: [])
        XCTAssertTrue(boot.isBootDisk)
        XCTAssertFalse(boot.isEligibleForRegistration)

        let internalDisk = DeviceEnumerator.makeDevice(
            bsdName: "disk0", description: description(internalDevice: true, removable: false),
            hardwareID: nil, bootDiskNames: [], volumes: [])
        XCTAssertFalse(internalDisk.isExternal)
        XCTAssertFalse(internalDisk.isEligibleForRegistration)
    }

    func testNonUSBAndNonWholeMediaAreNotEligible() {
        let thunderbolt = DeviceEnumerator.makeDevice(
            bsdName: "disk5", description: description(protocolName: "Thunderbolt"),
            hardwareID: nil, bootDiskNames: [], volumes: [])
        XCTAssertFalse(thunderbolt.isUSB)
        XCTAssertFalse(thunderbolt.isEligibleForRegistration)

        let slice = DeviceEnumerator.makeDevice(bsdName: "disk4s1",
                                                description: description(whole: false),
                                                hardwareID: nil, bootDiskNames: [], volumes: [])
        XCTAssertFalse(slice.isWholeDisk)
        XCTAssertFalse(slice.isEligibleForRegistration)
    }

    /// A missing key must never be read as "external and removable": the
    /// defaults have to fail closed.
    func testMissingKeysFailClosed() {
        let device = DeviceEnumerator.makeDevice(bsdName: "disk4", description: [:],
                                                 hardwareID: nil, bootDiskNames: [], volumes: [])
        XCTAssertFalse(device.isExternal)
        XCTAssertFalse(device.isRemovableOrEjectable)
        XCTAssertFalse(device.isUSB)
        XCTAssertFalse(device.isWholeDisk)
        XCTAssertEqual(device.sizeBytes, 0)
        XCTAssertEqual(device.displayName, "disk4")
        XCTAssertFalse(device.isEligibleForRegistration)
    }

    // MARK: - Matching a registration (PRD F27)

    func testDeviceMatchingUsesHardwareIdentityNotBSDName() {
        let drive = ManagedDrive(volumeUUID: "", displayName: "Stick", bookmark: Data(),
                                 capacityBytes: 32 << 30, kind: .flashed,
                                 hardwareID: HardwareID(vendorID: 1, productID: 2, serialNumber: "S1"),
                                 lastBSDName: "disk4")
        func candidate(bsdName: String, serial: String?, size: Int64 = 32 << 30) -> FlashDevice {
            FlashDevice(bsdName: bsdName, displayName: "Stick", sizeBytes: size, isWholeDisk: true,
                        isExternal: true, isRemovableOrEjectable: true, isUSB: true, isBootDisk: false,
                        hardwareID: HardwareID(vendorID: 1, productID: 2, serialNumber: serial),
                        volumeNames: [], volumeUUIDs: [])
        }
        // Same stick, different port → different BSD name, still a match.
        XCTAssertEqual(DeviceEnumerator.device(matching: drive,
                                               in: [candidate(bsdName: "disk9", serial: "S1")])?.bsdName,
                       "disk9")
        XCTAssertNil(DeviceEnumerator.device(matching: drive,
                                             in: [candidate(bsdName: "disk4", serial: "S2")]))
        // Weak identity (no serial on the candidate): capacity decides.
        XCTAssertNotNil(DeviceEnumerator.device(matching: drive,
                                                in: [candidate(bsdName: "disk4", serial: nil)]))
        XCTAssertNil(DeviceEnumerator.device(matching: drive,
                                             in: [candidate(bsdName: "disk4", serial: nil,
                                                            size: 64 << 30)]))
    }

    /// The boot volume must resolve to a real whole disk on this machine — a
    /// read-only sanity check on the one piece that cannot be faked.
    func testBootVolumeResolvesToAWholeDiskOnThisMachine() throws {
        let node = try XCTUnwrap(DeviceEnumerator.deviceNode(forVolumeAt: URL(fileURLWithPath: "/")))
        XCTAssertTrue(node.hasPrefix("/dev/disk"), node)
        let whole = try XCTUnwrap(DeviceEnumerator.wholeDiskName(forDeviceNode: node))
        let session = try XCTUnwrap(DASessionCreate(kCFAllocatorDefault))
        XCTAssertTrue(DeviceEnumerator.bootDiskNames(session: session).contains(whole))
    }
}
