import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F71: an ISO on a drive can be deleted — with its assignment, or on its
/// own when Isotope does not track it — and never while something else needs it.
@MainActor
final class ISODeletionTests: XCTestCase {
    private var root: URL!
    private var volume: URL!

    private let ubuntuFile = "ubuntu-24.04.4-desktop-amd64.iso"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeDeletionTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private nonisolated static func volumeInfo(_ url: URL, readOnly: Bool = false) -> VolumeInfo {
        VolumeInfo(url: url, volumeUUID: "UUID-A", name: "VENTOY",
                   capacityBytes: 64 << 30, availableBytes: 32 << 30,
                   isReadOnly: readOnly, isRemovable: true)
    }

    private var ubuntuEntry: CatalogEntry {
        CatalogEntry(id: "ubuntu", name: "Ubuntu Desktop", kind: .linux,
                     channels: [Channel(id: "lts", name: "LTS", provider: .checksumFile(
                         url: URL(string: "https://ubuntu.invalid/SHA256SUMS")!,
                         filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#))],
                     isBuiltIn: false)
    }

    /// A store whose drive is the temp folder: listing, sizes and deletes all
    /// touch real files, so a test sees what the user would.
    private func makeStore(readOnly: Bool = false) async throws -> (AppStore, ManagedDrive) {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let volumeURL = volume!
        store.driveProbe = DriveProbe(
            info: { url in Self.volumeInfo(url, readOnly: readOnly) },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in DriveScan.isoFileNames(in: try DriveAccess.fileNames(inFolder: volumeURL)) },
            isoSizes: { _, _ in (try? DriveAccess.isoSizes(inFolder: volumeURL)) ?? [:] },
            deleteISO: { _, _, name in
                try FileManager.default.removeItem(at: volumeURL.appendingPathComponent(name))
            })
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: volume)
        return (store, drive)
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: volume.appendingPathComponent(name).path)
    }

    // MARK: - With the assignment

    func testRemovingAndDeletingTakesTheFileAndTheRow() async throws {
        try TestFiles.write(volume.appendingPathComponent(ubuntuFile), size: 4096)
        let (store, drive) = try await makeStore()
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id))
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.fileName, ubuntuFile)

        try store.removeAssignment(id: assignment.id, from: drive.id, deletingFile: true)

        XCTAssertFalse(fileExists(ubuntuFile))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 0)
        XCTAssertTrue(store.detectedISOs(on: try XCTUnwrap(store.drive(id: drive.id))).isEmpty)
        // Said out loud, with what it gave back.
        let event = try XCTUnwrap(store.history.first)
        XCTAssertEqual(event.fileName, ubuntuFile)
        XCTAssertEqual(event.entryID, "ubuntu")
        XCTAssertTrue(event.message?.contains("freed") == true, event.message ?? "")
    }

    func testStopTrackingLeavesTheFileWhereItIs() async throws {
        try TestFiles.write(volume.appendingPathComponent(ubuntuFile), size: 4096)
        let (store, drive) = try await makeStore()
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id))
        store.scanAndReconcile(driveID: drive.id)

        try store.removeAssignment(id: assignment.id, from: drive.id)

        XCTAssertTrue(fileExists(ubuntuFile))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 0)
    }

    func testAFailedDeleteKeepsTheAssignment() async throws {
        try TestFiles.write(volume.appendingPathComponent(ubuntuFile), size: 4096)
        let (store, drive) = try await makeStore()
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id))
        store.scanAndReconcile(driveID: drive.id)
        store.driveProbe.deleteISO = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }

        XCTAssertThrowsError(try store.removeAssignment(id: assignment.id, from: drive.id, deletingFile: true))

        XCTAssertTrue(fileExists(ubuntuFile))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.map(\.id), [assignment.id])
    }

    func testAFileTwoAssignmentsShareIsNotDeletedWithOne() async throws {
        try TestFiles.write(volume.appendingPathComponent(ubuntuFile), size: 4096)
        let (store, drive) = try await makeStore()
        let first = try XCTUnwrap(store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id))
        store.scanAndReconcile(driveID: drive.id)
        // A pinned copy beside the tracker, holding the same file.
        var shared = try XCTUnwrap(store.drive(id: drive.id))
        var pinned = try XCTUnwrap(shared.assignments.first)
        pinned.id = UUID()
        pinned.updatePolicy = .keepAsIs
        shared.assignments.append(pinned)
        store.updateDrive(shared)

        let current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertNotNil(store.deleteBlocker(fileName: ubuntuFile, on: current, assignmentID: first.id))
        XCTAssertThrowsError(try store.removeAssignment(id: first.id, from: drive.id, deletingFile: true))
        XCTAssertTrue(fileExists(ubuntuFile))
    }

    // MARK: - Untracked files

    func testAnUntrackedFileCanBeDeletedOnItsOwn() async throws {
        try TestFiles.write(volume.appendingPathComponent("mystery.iso"), size: 2048)
        let (store, drive) = try await makeStore()
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertEqual(store.unrecognizedISOFiles(on: drive), ["mystery.iso"])

        try store.deleteISO(fileName: "mystery.iso", on: drive.id)

        XCTAssertFalse(fileExists("mystery.iso"))
        XCTAssertTrue(store.unrecognizedISOFiles(on: try XCTUnwrap(store.drive(id: drive.id))).isEmpty)
    }

    func testATrackedFileIsNotDeletedFromUnderItsAssignment() async throws {
        try TestFiles.write(volume.appendingPathComponent(ubuntuFile), size: 4096)
        let (store, drive) = try await makeStore()
        store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        store.scanAndReconcile(driveID: drive.id)

        XCTAssertThrowsError(try store.deleteISO(fileName: ubuntuFile, on: drive.id))
        XCTAssertTrue(fileExists(ubuntuFile))
    }

    func testAReadOnlyDriveRefusesTheDelete() async throws {
        try TestFiles.write(volume.appendingPathComponent("mystery.iso"), size: 2048)
        let (store, drive) = try await makeStore(readOnly: true)
        store.scanAndReconcile(driveID: drive.id)

        XCTAssertNotNil(store.deleteBlocker(fileName: "mystery.iso", on: drive))
        XCTAssertThrowsError(try store.deleteISO(fileName: "mystery.iso", on: drive.id))
        XCTAssertTrue(fileExists("mystery.iso"))
    }

    // MARK: - The live delete

    func testThePathIsNeverFollowedOutOfTheFolder() {
        XCTAssertThrowsError(try DriveAccess.deleteISO(bookmark: Data(), isoFolder: "", fileName: "../x.iso"))
        XCTAssertThrowsError(try DriveAccess.deleteISO(bookmark: Data(), isoFolder: "", fileName: ".."))
    }
}
