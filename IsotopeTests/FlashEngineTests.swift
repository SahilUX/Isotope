import IsotopeCore
import XCTest
@testable import Isotope

/// The whole flash pipeline (DESIGN §9) against fakes: no device, no authopen,
/// no administrator prompt, nothing written outside a temporary directory.
@MainActor
final class FlashEngineTests: XCTestCase {
    private var root: URL!
    private var isoURL: URL!
    private let isoSize = 300 * 1024      // several 64 KiB chunks

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeFlashTests-\(UUID().uuidString)")
        isoURL = try TestFiles.write(root.appendingPathComponent("arch-2026.08.01.iso"), size: isoSize)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeRelease() -> Release {
        Release(version: VersionToken.parse("2026.08.01")!,
                isoURL: URL(string: "https://example.com/arch-2026.08.01.iso")!,
                fileName: "arch-2026.08.01.iso",
                sha256: nil,
                sizeBytes: Int64(isoSize),
                checkedAt: Date())
    }

    private func makeStore() async -> (AppStore, ManagedDrive) {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        await store.loadAtLaunch()
        store.notifications = RecordingNotificationService()
        let drive = ManagedDrive(volumeUUID: "", displayName: "SanDisk Cruzer Blade",
                                 bookmark: Data(),
                                 assignments: [Assignment(entryID: "arch", channelID: "default")],
                                 capacityBytes: 32 << 30, kind: .flashed,
                                 hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583,
                                                        serialNumber: "SERIAL-1"),
                                 lastBSDName: "disk4")
        store.addDrive(drive)
        store.setRelease(makeRelease(), for: ReleaseKey(entryID: "arch", channelID: "default"))
        return (store, drive)
    }

    private func device(sizeBytes: Int64 = 32 << 30,
                        mutate: (inout FlashDeviceDescription) -> Void = { _ in })
        -> FlashDeviceDescription {
        var description = FlashDeviceDescription(bsdName: "disk4",
                                                 displayName: "SanDisk Cruzer Blade",
                                                 sizeBytes: sizeBytes)
        mutate(&description)
        return description
    }

    private func makeEngine(store: AppStore, io: FakeFlashDeviceIO) -> FlashEngine {
        FlashEngine(store: store, downloads: FakeISOProvider(behaviour: .file(isoURL)),
                    io: io, hashing: store.hashing)
    }

    private func request(drive: ManagedDrive, verify: Bool = true,
                         confirmedAt: Date = Date()) -> FlashRequest {
        FlashRequest(driveID: drive.id, driveName: drive.displayName,
                     assignmentID: drive.assignments[0].id, entryID: "arch", channelID: "default",
                     title: "Arch Linux", release: makeRelease(), bsdName: "disk4",
                     deviceName: "SanDisk Cruzer Blade", verifyAfterWrite: verify,
                     confirmedAt: confirmedAt)
    }

    private func run(_ engine: FlashEngine, _ request: FlashRequest) async {
        await engine.setChunkSize(64 * 1024)
        await engine.enqueue(request)
        await engine.drain()
    }

    // MARK: - Happy path

    func testSuccessfulFlashWritesVerifiesAndRecordsTheResult() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        // Every byte of the ISO reached the device, exactly once.
        XCTAssertEqual(io.written.count, isoSize)
        XCTAssertEqual(io.written, try Data(contentsOf: isoURL))
        XCTAssertTrue(io.finished)
        XCTAssertFalse(io.aborted)
        XCTAssertEqual(io.unmountCount, 1)
        XCTAssertEqual(io.writeOpenCount, 1)
        XCTAssertEqual(io.readOpenCount, 1)          // read-back verification
        // Gates run before the download *and* immediately before the write.
        XCTAssertGreaterThanOrEqual(io.describeCount, 2)

        let updated = try XCTUnwrap(store.drive(id: drive.id))
        let installed = try XCTUnwrap(updated.singleAssignment?.installed)
        XCTAssertEqual(installed.fileName, "arch-2026.08.01.iso")
        XCTAssertEqual(installed.version?.raw, "2026.08.01")
        XCTAssertTrue(installed.placedByApp)
        // PRD F27: the volume UUID the new image exposes is re-recorded.
        XCTAssertEqual(updated.volumeUUID, "NEW-VOLUME-UUID")
        XCTAssertNil(updated.flashFailure)

        XCTAssertEqual(store.operations.first?.phase, .completed)
        XCTAssertEqual(store.history.first?.outcome, .succeeded)
        XCTAssertTrue(store.history.first?.message?.contains("verified") == true)
        // PRD F23: the eject is offered once nothing is in flight.
        XCTAssertTrue(store.flashEjectOffers.contains(drive.id))
        XCTAssertFalse(store.drivesWithOperationsInFlight.contains(drive.id))
    }

    func testVerificationCanBeSkipped() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive, verify: false))

        XCTAssertEqual(io.readOpenCount, 0)
        XCTAssertEqual(io.written.count, isoSize)
        XCTAssertEqual(store.operations.first?.phase, .completed)
        XCTAssertFalse(store.history.first?.message?.contains("verified") == true)
    }

    // MARK: - Cancel from the Activity view

    /// The Activity row's Cancel used to reach only the update engine, so a
    /// flash could not be stopped from there at all.
    func testCancelInActivityReachesAFlash() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        let gated = GatedISOProvider(file: isoURL)
        let engine = FlashEngine(store: store, downloads: gated, io: io, hashing: store.hashing)
        store.flashEngine = engine
        let flash = request(drive: drive)
        await engine.enqueue(flash)
        await waitUntil { gated.started.count == 1 }

        store.cancelOperation(id: flash.id)
        await engine.drain()

        XCTAssertEqual(store.operations.first?.phase, .cancelled)
        XCTAssertTrue(io.written.isEmpty)
        XCTAssertEqual(io.unmountCount, 0)
    }

    // MARK: - Gates (PRD F29/F31)

    func testBootDiskIsRefusedBeforeAnythingIsWritten() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device { $0.isBootDisk = true })
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertTrue(io.written.isEmpty)
        XCTAssertEqual(io.unmountCount, 0)
        XCTAssertEqual(io.writeOpenCount, 0)
        XCTAssertEqual(store.history.first?.outcome, .failed)
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("macOS is running from") == true)
        // Nothing was written, so the stick is not left in an undefined state.
        XCTAssertNil(store.drive(id: drive.id)?.flashFailure)
    }

    func testADetachedDeviceFailsWithoutWriting() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: nil)
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertEqual(io.writeOpenCount, 0)
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("not attached") == true)
    }

    func testTooSmallDeviceIsRefused() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device(sizeBytes: Int64(isoSize) - 1))
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertTrue(io.written.isEmpty)
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("larger device") == true)
    }

    /// PRD F31: a confirmation from an old session must not flash anything.
    func testStaleConfirmationIsRefused() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive,
                                  confirmedAt: Date().addingTimeInterval(-2 * FlashEngine.confirmationLifetime)))

        XCTAssertEqual(io.describeCount, 0)
        XCTAssertTrue(io.written.isEmpty)
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("expired") == true)
    }

    // MARK: - Failures that leave the stick undefined (DESIGN §9)

    func testDeviceVanishingMidWriteFailsCleanlyAndFlagsTheDrive() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        io.vanish(afterBytes: Int64(isoSize) / 2)
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertTrue(io.aborted)
        XCTAssertFalse(io.finished)
        XCTAssertEqual(io.readOpenCount, 0)
        XCTAssertLessThan(io.written.count, isoSize)
        let failure = try XCTUnwrap(store.drive(id: drive.id)?.flashFailure)
        XCTAssertTrue(failure.reason.contains("disconnected"))
        XCTAssertTrue(failure.message.contains("Flash it again"))
        // The assignment is not marked installed by a flash that never finished.
        XCTAssertNil(store.drive(id: drive.id)?.singleAssignment?.installed)
        // DESIGN §9: staleness reflects the undefined state.
        let updated = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: updated), .needsAttention)
        XCTAssertEqual(store.history.first?.outcome, .failed)
    }

    func testReadBackMismatchFailsAndFlagsTheDrive() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        io.corruptReadBack()
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertEqual(io.written.count, isoSize)     // the write itself finished
        XCTAssertEqual(io.readOpenCount, 1)
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("does not match") == true)
        XCTAssertNotNil(store.drive(id: drive.id)?.flashFailure)
        XCTAssertNil(store.drive(id: drive.id)?.singleAssignment?.installed)
    }

    // MARK: - Authorisation

    func testCancelledAuthorisationLeavesTheDeviceUntouched() async throws {
        let (store, drive) = await makeStore()
        let io = FakeFlashDeviceIO(description: device())
        io.set(openBehaviour: .authorizationCancelled)
        let engine = makeEngine(store: store, io: io)

        await run(engine, request(drive: drive))

        XCTAssertTrue(io.written.isEmpty)
        XCTAssertEqual(io.unmountCount, 1)            // unmount happens first, harmlessly
        XCTAssertTrue(store.operations.first?.errorMessage?.contains("not authorised") == true)
        // Nothing was written: the device is still whatever it was.
        XCTAssertNil(store.drive(id: drive.id)?.flashFailure)
    }

}
