import IsotopeCore
import XCTest
@testable import Isotope

/// PRD §5.4 / F41: the Downloads watch that finds a manually downloaded ISO.
///
/// The bug these exist for: the watch built its pattern from the entry's
/// *title*, so "Windows 11" became `^Windows.*\.iso$` — which never matches
/// Microsoft's own `Win11_25H2_English_x64_v2.iso`. The file sat in the folder
/// while the sheet said "No matching ISO yet". The catalog already knows what
/// this media is called; that is now the only thing consulted.
@MainActor
final class DownloadsWatchTests: XCTestCase {
    private var folder: URL!

    /// The real pattern the shipped catalog carries for Windows 11.
    private let catalogPattern =
        #"^Win11(?:_(\d{2}H\d)|_\d{4})?_[A-Za-z]+(?:[ _-][A-Za-z]+)*_(?:x64|x32|x86|arm64)(?:_?v\d+)?\.iso$"#

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeDownloadsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, size: Int = 1024) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0, count: size).write(to: url)
        return url
    }

    // MARK: - The names Microsoft actually gives its media

    func testMicrosoftsOwnFilenamesAreFound() throws {
        // Every one of these is a real shape from Microsoft's download page.
        let names = [
            "Win11_25H2_English_x64_v2.iso",   // the one that was missed
            "Win11_25H2_English_x64v2.iso",
            "Win11_25H2_English_x64.iso",
            "Win11_25H2_EnglishInternational_x64.iso",
            "Win10_22H2_English_x64.iso",
        ]
        for name in names {
            try write(name)
        }
        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern)
        XCTAssertEqual(Set(found.matching.map(\.fileName)),
                       Set(names.filter { $0.hasPrefix("Win11") }),
                       "Windows 11's pattern should claim exactly its own media")
        XCTAssertEqual(found.other.map(\.fileName), ["Win10_22H2_English_x64.iso"])
        XCTAssertTrue(found.isReadable)
    }

    func testTheTitleDerivedPatternWouldHaveMissedIt() {
        // The regression, stated: this is what the sheet used to watch for.
        let old = try! PatternMatcher(#"(?i)^Windows.*\.iso$"#, caseInsensitive: true)
        XCTAssertFalse(old.matchesAnywhere("Win11_25H2_English_x64_v2.iso"))
        let now = try! PatternMatcher(catalogPattern, caseInsensitive: true)
        XCTAssertTrue(now.matchesAnywhere("Win11_25H2_English_x64_v2.iso"))
    }

    // MARK: - Never a dead end

    func testEveryOtherISOIsStillOfferedWhenNothingMatches() throws {
        try write("some-windows-copy.iso")
        try write("ubuntu-24.04.4-desktop-amd64.iso")
        try write("notes.txt")

        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern)
        XCTAssertTrue(found.matching.isEmpty)
        // A renamed file must not leave the user with an empty list: it is right
        // there in the folder, so offer it.
        XCTAssertEqual(Set(found.other.map(\.fileName)),
                       ["some-windows-copy.iso", "ubuntu-24.04.4-desktop-amd64.iso"])
    }

    // MARK: - Not someone else's media

    /// The report: the Windows 11 sheet offered `Win10_22H2_English_x64v1.iso`
    /// because the fallback listed *every* ISO. A file another catalog entry
    /// recognises is that entry's media, not a renamed Windows 11.
    func testTheFallbackLeavesOutOtherCatalogImages() throws {
        let win10Pattern =
            #"^Win10(?:_(\d{2}H\d)|_\d{4})?_[A-Za-z]+(?:[ _-][A-Za-z]+)*_(?:x64|x32|x86|arm64)(?:_?v\d+)?\.iso$"#
        try write("Win10_22H2_English_x64v1.iso")
        try write("Windows11_Client_x64_en-us_26300_9457.iso")

        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern,
                                          excluding: [win10Pattern])
        XCTAssertTrue(found.matching.isEmpty)
        XCTAssertEqual(found.other.map(\.fileName), ["Windows11_Client_x64_en-us_26300_9457.iso"])
    }

    /// Against the shipped catalog: no other entry's pattern is so loose that
    /// it swallows a renamed Windows 11 ISO, and Windows 10's media is excluded.
    func testTheShippedCatalogExcludesWindows10ButNotWindows11() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeWatchCatalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = Bundle(for: AppStore.self).url(forResource: "catalog", withExtension: "json")
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: catalog)
        await store.loadAtLaunch()
        let excluded = store.otherMediaFileNamePatterns(excludingEntryID: "windows-11")
        XCTAssertFalse(excluded.isEmpty)

        try write("Win10_22H2_English_x64v1.iso")
        try write("Windows11_Client_x64_en-us_26300_9457.iso")
        try write("my-windows-11.iso")
        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern, excluding: excluded)
        XCTAssertEqual(Set(found.other.map(\.fileName)),
                       ["Windows11_Client_x64_en-us_26300_9457.iso", "my-windows-11.iso"])
    }

    func testNewestFirst() throws {
        let older = try write("Win11_24H2_English_x64.iso")
        let newer = try write("Win11_25H2_English_x64_v2.iso")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: newer.path)

        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern)
        XCTAssertEqual(found.matching.first?.fileName, "Win11_25H2_English_x64_v2.iso")
    }

    func testAnUnreadableFolderIsNotTheSameAsAnEmptyOne() {
        let missing = folder.appendingPathComponent("nope", isDirectory: true)
        let found = DownloadsWatcher.scan(folder: missing, pattern: catalogPattern)
        XCTAssertFalse(found.isReadable)
        XCTAssertTrue(found.matching.isEmpty)
        // The sheet says "grant access" for this, not "your download is late".
    }

    func testNonISOFilesAreIgnored() throws {
        try write("Win11_25H2_English_x64.iso.part")
        try write("Win11_25H2_English_x64.dmg")
        let found = DownloadsWatcher.scan(folder: folder, pattern: catalogPattern)
        XCTAssertTrue(found.matching.isEmpty)
        XCTAssertTrue(found.other.isEmpty)
    }

    // MARK: - Where the pattern comes from

    func testTheSheetWatchesForWhateverTheCatalogSays() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeWatchStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows,
            channels: [Channel(id: "default", name: "Current release", provider: .windowsManual(
                infoURL: URL(string: "https://microsoft.invalid/w11")!,
                downloadPage: URL(string: "https://microsoft.invalid/w11")!,
                fileNamePattern: catalogPattern))],
            isBuiltIn: false))

        XCTAssertEqual(store.mediaFileNamePattern(entryID: "windows-11", channelID: "default"),
                       catalogPattern)
        // An entry with no pattern falls back to something loose rather than to
        // something wrong.
        XCTAssertNil(store.mediaFileNamePattern(entryID: "nope", channelID: "default"))
    }
}
