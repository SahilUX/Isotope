import XCTest
@testable import IsotopeCore

/// v1.1 model layer: drives.json migration, hardware identity, the flashed-drive
/// invariant, and which catalog entries may be flashed (PRD F26/F27/F32).
final class FlashModelTests: XCTestCase {
    // MARK: - Migration (PRD F26)

    func testDrivesWrittenBeforeV11DecodeAsVentoyDrives() throws {
        // Exactly what v1 wrote: no `kind`, no `hardwareID`.
        let json = """
        [{
          "id": "6B4B2B7C-1E2F-4C41-9F6A-6D9F8E0B1A22",
          "volumeUUID": "UUID-A",
          "displayName": "VENTOY",
          "bookmark": "AQID",
          "isoFolder": "ISOs",
          "keepOldVersions": false,
          "assignments": []
        }]
        """
        let drives = try JSONStore.loadJSON([ManagedDrive].self, from: Data(json.utf8))
        let drive = try XCTUnwrap(drives.first)
        XCTAssertEqual(drive.kind, .ventoy)
        XCTAssertFalse(drive.isFlashed)
        XCTAssertNil(drive.hardwareID)
        XCTAssertNil(drive.flashFailure)
        XCTAssertEqual(drive.isoFolder, "ISOs")
    }

    func testFlashedDriveRoundTripsThroughJSON() throws {
        let hardware = HardwareID(vendorID: 0x0781, productID: 0x5583,
                                  serialNumber: "4C530001", vendorName: "SanDisk",
                                  productName: "Cruzer Blade")
        let drive = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade",
                                 bookmark: Data(), assignments: [Assignment(entryID: "arch", channelID: "default")],
                                 capacityBytes: 32 << 30, kind: .flashed,
                                 hardwareID: hardware, lastBSDName: "disk4",
                                 flashFailure: FlashFailure(reason: "device detached",
                                                            date: Date(timeIntervalSince1970: 1_700_000_000)))
        let data = try JSONStore.makeEncoder().encode(drive)
        let decoded = try JSONStore.loadJSON(ManagedDrive.self, from: data)
        XCTAssertEqual(decoded, drive)
        XCTAssertEqual(decoded.kind, .flashed)
        XCTAssertEqual(decoded.hardwareID, hardware)
        XCTAssertEqual(decoded.lastBSDName, "disk4")
        XCTAssertEqual(decoded.flashFailure?.reason, "device detached")
    }

    func testMissingOptionalFieldsDoNotBreakDecoding() throws {
        let json = """
        {"id":"6B4B2B7C-1E2F-4C41-9F6A-6D9F8E0B1A22","volumeUUID":"","displayName":"Stick","kind":"flashed"}
        """
        let drive = try JSONStore.loadJSON(ManagedDrive.self, from: Data(json.utf8))
        XCTAssertEqual(drive.kind, .flashed)
        XCTAssertEqual(drive.bookmark, Data())
        XCTAssertTrue(drive.assignments.isEmpty)
    }

    // MARK: - Hardware identity (PRD F27)

    func testSerialNumbersDecideIdentityWhenBothSidesHaveOne() {
        let registered = HardwareID(vendorID: 1, productID: 2, serialNumber: "AAA")
        XCTAssertTrue(registered.matches(HardwareID(vendorID: 1, productID: 2, serialNumber: "aaa")))
        XCTAssertFalse(registered.matches(HardwareID(vendorID: 1, productID: 2, serialNumber: "BBB")))
        XCTAssertFalse(registered.matches(HardwareID(vendorID: 9, productID: 2, serialNumber: "AAA")))
        XCTAssertTrue(registered.isStrongIdentity)
    }

    func testWeakIdentityFallsBackToVendorProductAndCapacity() {
        let registered = HardwareID(vendorID: 1, productID: 2)      // no serial
        XCTAssertFalse(registered.isStrongIdentity)
        let candidate = HardwareID(vendorID: 1, productID: 2)
        // Same model, same capacity → treated as the same stick.
        XCTAssertTrue(registered.matches(candidate, sizeBytes: 32 << 30, candidateSizeBytes: 32 << 30))
        // Same model, different capacity → definitely a different stick.
        XCTAssertFalse(registered.matches(candidate, sizeBytes: 32 << 30, candidateSizeBytes: 64 << 30))
        // Capacity unknown on one side: vendor+product is all there is.
        XCTAssertTrue(registered.matches(candidate, sizeBytes: nil, candidateSizeBytes: 64 << 30))
    }

    func testBlankSerialIsTreatedAsAbsent() {
        let id = HardwareID(vendorID: 1, productID: 2, serialNumber: "   ")
        XCTAssertNil(id.serialNumber)
        XCTAssertFalse(id.isStrongIdentity)
        XCTAssertTrue(id.displayText.contains("0x0001:0x0002"))
    }

    // MARK: - One assignment per flashed drive (PRD F26)

    func testFlashedDriveKeepsExactlyOneAssignment() {
        let first = Assignment(entryID: "arch", channelID: "default")
        var drive = ManagedDrive(volumeUUID: "", displayName: "Stick", bookmark: Data(),
                                 assignments: [first, Assignment(entryID: "tails", channelID: "default")],
                                 kind: .flashed)
        XCTAssertFalse(drive.canAddAssignment)
        drive.enforceAssignmentInvariant()
        XCTAssertEqual(drive.assignments.map(\.id), [first.id])
        XCTAssertEqual(drive.singleAssignment?.entryID, "arch")

        var ventoy = ManagedDrive(volumeUUID: "U", displayName: "VENTOY", bookmark: Data(),
                                  assignments: [first, Assignment(entryID: "tails", channelID: "default")])
        XCTAssertTrue(ventoy.canAddAssignment)
        ventoy.enforceAssignmentInvariant()
        XCTAssertEqual(ventoy.assignments.count, 2)
        XCTAssertNil(ventoy.singleAssignment)
    }

    func testAFailedFlashIsNeverDisplayedAsUpToDate() {
        var drive = ManagedDrive(volumeUUID: "", displayName: "Stick", bookmark: Data(), kind: .flashed)
        XCTAssertEqual(drive.displayedStaleness(.upToDate), .upToDate)
        drive.flashFailure = FlashFailure(reason: "verification mismatch")
        XCTAssertEqual(drive.displayedStaleness(.upToDate), .stale)
        XCTAssertEqual(drive.displayedStaleness(.notInstalled), .stale)
        XCTAssertTrue(drive.flashFailure!.message.contains("Flash it again"))
    }

    // MARK: - Flashability (PRD F32)

    func testWindowsManualEntriesAreNotFlashable() {
        let windows = CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows,
            channels: [Channel(id: "default", name: "Default",
                               provider: .windowsManual(infoURL: URL(string: "https://example.com/info")!,
                                                        downloadPage: URL(string: "https://example.com/dl")!))],
            isBuiltIn: true)
        let arch = CatalogEntry(
            id: "arch", name: "Arch Linux", kind: .linux,
            channels: [Channel(id: "default", name: "Default",
                               provider: .jsonFeed(url: URL(string: "https://example.com/f.json")!,
                                                   spec: JSONFeedSpec(versionKeys: ["version"])))],
            isBuiltIn: true)

        XCTAssertFalse(windows.hasFlashableChannel)
        XCTAssertTrue(arch.hasFlashableChannel)
        XCTAssertEqual(FlashEligibility.flashableEntries([windows, arch]).map(\.id), ["arch"])
    }

    func testMixedEntryOffersOnlyItsFlashableChannels() {
        let entry = CatalogEntry(
            id: "mixed", name: "Mixed", kind: .custom,
            channels: [
                Channel(id: "iso", name: "ISO",
                        provider: .staticURL(url: URL(string: "https://example.com/x.iso")!, checksumURL: nil)),
                Channel(id: "manual", name: "Manual",
                        provider: .windowsManual(infoURL: URL(string: "https://example.com/i")!,
                                                 downloadPage: URL(string: "https://example.com/d")!)),
            ],
            isBuiltIn: false)
        XCTAssertEqual(entry.flashableChannels.map(\.id), ["iso"])
    }
}
