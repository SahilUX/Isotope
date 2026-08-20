import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F43 addendum, app side: reading the build out of the Windows media on a
/// drive and recording it against the assignment.
///
/// Offline and stick-free. The parsing half runs against a synthetic
/// `install.wim` on disk — a real header and a real UTF-16 XML block, just not
/// six gigabytes of Windows around it — and the store half runs against an
/// injected `DriveProbe`, so no ISO is ever mounted here.
@MainActor
final class WindowsBuildDetectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeWindowsBuildTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func writeWIM(build: Int, spBuild: Int, named name: String = "install.wim") throws -> URL {
        let xml = """
        <WIM><TOTALBYTES>5726443520</TOTALBYTES><IMAGE INDEX="1"><WINDOWS><ARCH>9</ARCH>\
        <EDITIONID>Professional</EDITIONID><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR>\
        <BUILD>\(build)</BUILD><SPBUILD>\(spBuild)</SPBUILD><SPLEVEL>0</SPLEVEL></VERSION>\
        </WINDOWS></IMAGE></WIM>
        """
        var xmlData = Data([0xFF, 0xFE])
        xmlData.append(xml.data(using: .utf16LittleEndian)!)

        var header = Data(repeating: 0, count: WindowsImageReader.headerLength)
        header.replaceSubrange(0..<8, with: Array("MSWIM\0\0\0".utf8))
        func write(_ value: UInt64, at offset: Int) {
            for index in 0..<8 { header[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        }
        write(UInt64(xmlData.count), at: 0x48)
        write(UInt64(WindowsImageReader.headerLength), at: 0x50)
        write(UInt64(xmlData.count), at: 0x58)

        let url = root.appendingPathComponent(name)
        try (header + xmlData).write(to: url)
        return url
    }

    private func makeStore(volumes: [URL: VolumeInfo] = [:], listing: [String] = [],
                           builds: [String: String] = [:]) -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { url in
                guard let info = volumes[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data("bookmark:\(url.path)".utf8) },
            listISOs: { _, _ in listing },
            windowsBuild: { _, _, fileName in builds[fileName] })
        return store
    }

    private var windowsEntry: CatalogEntry {
        CatalogEntry(id: "windows-11", name: "Windows 11", kind: .windows,
                     channels: [Channel(id: "default", name: "Current release",
                                        provider: .windowsManual(
                                            infoURL: URL(string: "https://microsoft.invalid/w11")!,
                                            downloadPage: URL(string: "https://microsoft.invalid/w11")!,
                                            fileNamePattern: #"^Win11_(\d{2}H\d)_[A-Za-z]+_x64\.iso$"#))],
                     isBuiltIn: false)
    }

    private func volume(_ path: String, uuid: String) -> (URL, VolumeInfo) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (url, VolumeInfo(url: url, volumeUUID: uuid, name: "VENTOY",
                                capacityBytes: 64_000_000_000, availableBytes: 40_000_000_000,
                                isReadOnly: false, isRemovable: true))
    }

    /// The inspection runs off the main actor after the scan, so the test waits
    /// for it rather than assuming an ordering.
    private func waitForBuild(on store: AppStore, driveID: UUID) async -> String? {
        for _ in 0..<100 {
            if let build = store.drive(id: driveID)?.assignments.first?.installed?.build {
                return build
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: - Reading the image (the half that touches real bytes)

    func testReadsTheBuildOutOfAnInstallWIMOnDisk() throws {
        let wim = try writeWIM(build: 26200, spBuild: 6584)
        let identity = try XCTUnwrap(WindowsISOInspector.identity(ofImageAt: wim))
        XCTAssertEqual(identity.build, "26200.6584")
        XCTAssertEqual(identity.editions, ["Professional"])
    }

    func testAFileThatIsNotAWIMSaysNothing() throws {
        let url = root.appendingPathComponent("install.wim")
        try Data("not a windows image".utf8).write(to: url)
        XCTAssertNil(WindowsISOInspector.identity(ofImageAt: url))
    }

    func testAMissingFileSaysNothing() {
        XCTAssertNil(WindowsISOInspector.identity(ofImageAt: root.appendingPathComponent("absent.wim")))
    }

    func testFindsTheInstallImageWhateverCaseTheMediaUses() throws {
        let mount = root.appendingPathComponent("mount")
        let sources = mount.appendingPathComponent("Sources")   // Microsoft's own casing varies
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data().write(to: sources.appendingPathComponent("install.esd"))

        let found = try XCTUnwrap(WindowsISOInspector.installImageURL(inMountedISO: mount))
        XCTAssertEqual(found.lastPathComponent, "install.esd")
        // A disc with no `sources` directory is not Windows media.
        XCTAssertNil(WindowsISOInspector.installImageURL(inMountedISO: root))
    }

    // MARK: - Recording it against the assignment

    func testAScanRecordsTheBuildOfWindowsMediaOnTheDrive() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-W")
        let store = makeStore(volumes: [url: info],
                              listing: ["Win11_25H2_English_x64.iso"],
                              builds: ["Win11_25H2_English_x64.iso": "26200.6584"])
        await store.loadAtLaunch()
        store.addCustomEntry(windowsEntry)
        let drive = try store.registerDrive(at: url)
        store.addAssignment(entryID: "windows-11", channelID: "default", to: drive.id)

        store.scanAndReconcile(driveID: drive.id)
        let build = await waitForBuild(on: store, driveID: drive.id)
        XCTAssertEqual(build, "26200.6584")

        // And it is the drive's own state, so it survives a relaunch.
        let reloaded = makeStore(volumes: [url: info])
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drives.first?.assignments.first?.installed?.build, "26200.6584")
    }

    func testTheSameFileIsNeverMountedTwice() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-W")
        let counter = Counter()
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { requested in
                guard requested == url else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data("bookmark:\(url.path)".utf8) },
            listISOs: { _, _ in ["Win11_25H2_English_x64.iso"] },
            windowsBuild: { _, _, _ in
                counter.increment()
                return "26200.6584"
            })
        await store.loadAtLaunch()
        store.addCustomEntry(windowsEntry)
        let drive = try store.registerDrive(at: url)
        store.addAssignment(entryID: "windows-11", channelID: "default", to: drive.id)

        store.scanAndReconcile(driveID: drive.id)
        _ = await waitForBuild(on: store, driveID: drive.id)
        // Mounting a 6 GB image is expensive; re-scanning must not repeat it.
        for _ in 0..<3 { store.scanAndReconcile(driveID: drive.id) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testAnImageThatWillNotSayIsLeftUnknown() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-W")
        let store = makeStore(volumes: [url: info],
                              listing: ["Win11_25H2_English_x64.iso"], builds: [:])
        await store.loadAtLaunch()
        store.addCustomEntry(windowsEntry)
        let drive = try store.registerDrive(at: url)
        store.addAssignment(entryID: "windows-11", channelID: "default", to: drive.id)

        store.scanAndReconcile(driveID: drive.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Nothing invented: the row keeps showing the release alone.
        XCTAssertNil(store.drive(id: drive.id)?.assignments.first?.installed?.build)
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.displayVersion, "25H2")
    }

    func testABuildIsNotStampedOntoADifferentFile() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-W")
        let store = makeStore(volumes: [url: info], listing: ["Win11_25H2_English_x64.iso"])
        await store.loadAtLaunch()
        store.addCustomEntry(windowsEntry)
        let drive = try store.registerDrive(at: url)
        store.addAssignment(entryID: "windows-11", channelID: "default", to: drive.id)
        store.scanAndReconcile(driveID: drive.id)
        let assignmentID = try XCTUnwrap(store.drive(id: drive.id)?.assignments.first?.id)

        // The answer arrives after the drive moved on to a different ISO.
        store.recordWindowsBuild("26200.6584", forAssignment: assignmentID,
                                 on: drive.id, fileName: "Win11_24H2_English_x64.iso")
        XCTAssertNil(store.drive(id: drive.id)?.assignments.first?.installed?.build)
    }

    func testNonWindowsAssignmentsAreNeverMounted() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-W")
        let counter = Counter()
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { requested in
                guard requested == url else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data("bookmark:\(url.path)".utf8) },
            listISOs: { _, _ in ["ubuntu-24.04.4-desktop-amd64.iso"] },
            windowsBuild: { _, _, _ in
                counter.increment()
                return "26200.6584"
            })
        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "ubuntu-desktop", name: "Ubuntu Desktop", kind: .linux,
            channels: [Channel(id: "lts", name: "LTS", provider: .checksumFile(
                url: URL(string: "https://ubuntu.invalid/SHA256SUMS")!,
                filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#))],
            isBuiltIn: false))
        let drive = try store.registerDrive(at: url)
        store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts", to: drive.id)

        store.scanAndReconcile(driveID: drive.id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.value, 0)
    }
}

/// Counts calls from the concurrent `windowsBuild` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
