import XCTest
@testable import IsotopeCore

final class VentoyVersionTests: XCTestCase {
    // MARK: - Version type

    func testParsesNumericComponents() {
        XCTAssertEqual(VentoyVersion("1.1.18")?.components, [1, 1, 18])
        XCTAssertEqual(VentoyVersion("1.0.99")?.components, [1, 0, 99])
        XCTAssertEqual(VentoyVersion("2")?.components, [2])
        XCTAssertEqual(VentoyVersion("1.1.14")?.description, "1.1.14")
    }

    func testRefusesNonNumericText() {
        for bad in ["", "1.1.x", "v1.1.14", "1..14", "1.1.", ".1", " 1.1.14", "1.1.14 ",
                    "1.1.14-beta", "١.١.١٤", "1.1.9999999", "1.2.3.4.5.6.7"] {
            XCTAssertNil(VentoyVersion(bad), "\(bad.debugDescription) should not parse")
        }
    }

    func testOrdersNumericallyNotLexically() throws {
        let v1_1_9 = try XCTUnwrap(VentoyVersion("1.1.9"))
        let v1_1_14 = try XCTUnwrap(VentoyVersion("1.1.14"))
        let v1_1_18 = try XCTUnwrap(VentoyVersion("1.1.18"))
        let v1_0_99 = try XCTUnwrap(VentoyVersion("1.0.99"))
        XCTAssertLessThan(v1_1_9, v1_1_14)
        XCTAssertLessThan(v1_1_14, v1_1_18)
        XCTAssertLessThan(v1_0_99, v1_1_9)
        XCTAssertEqual(VentoyVersion("1.1"), VentoyVersion("1.1.0"))
        XCTAssertEqual(Set([VentoyVersion("1.1")!, VentoyVersion("1.1.0")!]).count, 1)
        XCTAssertLessThan(VentoyVersion("1.1")!, VentoyVersion("1.1.1")!)
    }

    // MARK: - Secure Boot CA policy

    func testNoticeOnlyBelow1_1_14() {
        XCTAssertTrue(VentoyVersion("1.1.13")!.needsSecureBootCANotice)
        XCTAssertTrue(VentoyVersion("1.1.9")!.needsSecureBootCANotice)
        XCTAssertTrue(VentoyVersion("1.0.99")!.needsSecureBootCANotice)
        XCTAssertFalse(VentoyVersion("1.1.14")!.needsSecureBootCANotice)
        XCTAssertFalse(VentoyVersion("1.1.18")!.needsSecureBootCANotice)
        XCTAssertFalse(VentoyVersion("1.2")!.needsSecureBootCANotice)
    }

    func testUnknownReadingNeverWarns() {
        XCTAssertFalse(VentoyVersionReading.unknown("mount failed").needsSecureBootCANotice)
        XCTAssertNil(VentoyVersionReading.unknown("x").version)
        XCTAssertTrue(VentoyVersionReading.known(VentoyVersion("1.0.97")!).needsSecureBootCANotice)
    }

    // MARK: - grub.cfg

    func testParsesGrubConfigExcerpt() {
        // The shape of Ventoy's own /grub/grub.cfg on VTOYEFI.
        let excerpt = """
        #************************************************************************************
        # Copyright (c) 2020, longpanda <admin@ventoy.net>
        #************************************************************************************

        function ventoy_pause {
            echo "press Enter to continue ......"
            read vtTmpPause
        }

        set VENTOY_VERSION="1.1.18"

        #ACPI not compatible with Window7/8, so disable by default
        set VTOY_PARAM_NO_ACPI=1
        """
        XCTAssertEqual(VentoyVersion.parse(grubConfig: excerpt), VentoyVersion("1.1.18"))
    }

    func testToleratesWhitespaceCRLFAndNoSet() {
        XCTAssertEqual(VentoyVersion.parse(grubConfig: "  set\tVENTOY_VERSION = \"1.1.10\"\r\n"),
                       VentoyVersion("1.1.10"))
        XCTAssertEqual(VentoyVersion.parse(grubConfig: "VENTOY_VERSION=\"1.0.99\""),
                       VentoyVersion("1.0.99"))
        XCTAssertEqual(VentoyVersion.parse(grubConfig: "\tset VENTOY_VERSION=\"1.1.14\" # pinned"),
                       VentoyVersion("1.1.14"))
    }

    func testSkipsCommentsAndLookalikes() {
        let text = """
        # set VENTOY_VERSION="0.0.1"
        set VENTOY_VERSION_EXTRA="9.9.9"
        settings VENTOY_VERSION="8.8.8"
        echo $VENTOY_VERSION
        set VENTOY_VERSION="1.1.12"
        """
        XCTAssertEqual(VentoyVersion.parse(grubConfig: text), VentoyVersion("1.1.12"))
    }

    func testGarbageGivesNil() {
        for text in ["", "\u{0}\u{1}\u{2}", "set VENTOY_VERSION=1.1.18", "set VENTOY_VERSION=\"1.1.18",
                     "set VENTOY_VERSION=\"\"", "set VENTOY_VERSION=\"latest\"",
                     String(repeating: "x", count: 10_000)] {
            XCTAssertNil(VentoyVersion.parse(grubConfig: text), "input: \(text.prefix(40).debugDescription)")
        }
    }

    // MARK: - Partition rule

    private func candidate(dataWholeDisk: String = "disk4", partition: String = "disk4s2",
                           partitionWhole: String = "disk4", size: Int64 = 32 * 1024 * 1024,
                           content: String? = "0xEF", isUSB: Bool = true, isExternal: Bool = true,
                           isBootDisk: Bool = false, diskName: String = "disk4") -> VentoyEFIPartitionCandidate {
        VentoyEFIPartitionCandidate(
            dataWholeDisk: dataWholeDisk, partitionBSDName: partition, partitionWholeDisk: partitionWhole,
            sizeBytes: size, content: content,
            disk: FlashDeviceDescription(bsdName: diskName, displayName: "Stick", sizeBytes: 64_000_000_000,
                                         isExternal: isExternal, isUSB: isUSB, isBootDisk: isBootDisk))
    }

    func testAcceptsMBRAndGPTVentoyPartition() {
        XCTAssertNil(VentoyEFIPartitionRule.refusal(for: candidate()))
        XCTAssertNil(VentoyEFIPartitionRule.refusal(
            for: candidate(content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")))
        XCTAssertNil(VentoyEFIPartitionRule.refusal(for: candidate(content: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")))
    }

    func testRefusesWrongSizeOrType() {
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(size: 8 * 1024 * 1024)))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(size: 200 * 1024 * 1024)))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(content: "Windows_NTFS")))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(content: "0x0B")))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(content: nil)))
    }

    func testRefusesAnotherDisk() {
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(partitionWhole: "disk5")))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(partition: "disk5s2")))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(partition: "disk4s3")))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(diskName: "disk5")))
    }

    func testRefusesNonUSBOrInternalOrBootDisk() {
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(isUSB: false)))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(isExternal: false)))
        XCTAssertNotNil(VentoyEFIPartitionRule.refusal(for: candidate(isBootDisk: true)))
    }
}
