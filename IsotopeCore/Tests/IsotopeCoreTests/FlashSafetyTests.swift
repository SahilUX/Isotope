import XCTest
@testable import IsotopeCore

/// PRD F29/F31 safety gates. The whole point of keeping this logic pure is that
/// every refusal can be asserted here, with no device anywhere near the test.
final class FlashSafetyTests: XCTestCase {
    private func device(_ mutate: (inout FlashDeviceDescription) -> Void = { _ in })
        -> FlashDeviceDescription {
        var description = FlashDeviceDescription(bsdName: "disk4", displayName: "SanDisk Cruzer Blade",
                                                 sizeBytes: 32 << 30)
        mutate(&description)
        return description
    }

    func testAWellBehavedExternalUSBStickPasses() {
        XCTAssertNil(FlashSafetyGate.evaluate(device: device(), isoSizeBytes: 4 << 30))
        XCTAssertTrue(FlashSafetyGate.isEligibleForRegistration(device()))
    }

    func testEachGateReportsItsOwnReason() {
        let iso: Int64 = 4 << 30
        let cases: [(name: String, device: FlashDeviceDescription, expected: FlashGateFailure)] = [
            ("boot disk", device { $0.isBootDisk = true },
             .bootDisk(deviceName: "SanDisk Cruzer Blade")),
            ("detached", device { $0.isAttached = false },
             .notAttached(deviceName: "SanDisk Cruzer Blade")),
            ("slice", device { $0.isWholeDisk = false; $0.bsdName = "disk4s1" },
             .notWholeDisk(bsdName: "disk4s1")),
            ("internal", device { $0.isExternal = false },
             .notExternal(deviceName: "SanDisk Cruzer Blade")),
            ("fixed", device { $0.isRemovableOrEjectable = false },
             .notRemovable(deviceName: "SanDisk Cruzer Blade")),
            ("thunderbolt", device { $0.isUSB = false },
             .notUSB(deviceName: "SanDisk Cruzer Blade")),
            ("too small", device { $0.sizeBytes = 2 << 30 },
             .tooSmall(deviceName: "SanDisk Cruzer Blade", deviceBytes: 2 << 30, requiredBytes: iso)),
        ]
        for testCase in cases {
            XCTAssertEqual(FlashSafetyGate.evaluate(device: testCase.device, isoSizeBytes: iso),
                           testCase.expected, testCase.name)
            XCTAssertFalse(testCase.expected.reason.isEmpty, testCase.name)
        }
    }

    /// The boot disk is the mistake that costs a Mac, so it is reported first
    /// even when the device is also detached, internal and too small.
    func testTheBootDiskIsReportedBeforeAnythingElse() {
        let worst = device {
            $0.isBootDisk = true
            $0.isAttached = false
            $0.isExternal = false
            $0.isUSB = false
            $0.sizeBytes = 1
        }
        XCTAssertEqual(FlashSafetyGate.evaluate(device: worst, isoSizeBytes: 4 << 30),
                       .bootDisk(deviceName: "SanDisk Cruzer Blade"))
        XCTAssertFalse(FlashSafetyGate.isEligibleForRegistration(worst))
    }

    func testExactlyISOSizedDevicePasses() {
        let exact = device { $0.sizeBytes = 4 << 30 }
        XCTAssertNil(FlashSafetyGate.evaluate(device: exact, isoSizeBytes: 4 << 30))
    }

    /// Registration happens before an image is chosen, so the size gate has to
    /// be skippable without weakening any other gate.
    func testRegistrationEligibilitySkipsOnlyTheSizeGate() {
        let tiny = device { $0.sizeBytes = 1 }
        XCTAssertNil(FlashSafetyGate.evaluate(device: tiny, isoSizeBytes: nil))
        XCTAssertTrue(FlashSafetyGate.isEligibleForRegistration(tiny))
        XCTAssertFalse(FlashSafetyGate.isEligibleForRegistration(device { $0.isBootDisk = true }))
    }
}
