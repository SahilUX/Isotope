import XCTest
@testable import IsotopeCore

/// Compiling an `NSRegularExpression` costs tens of microseconds, which is
/// nothing until it happens in a loop. Matching a drive's unclaimed files
/// against every channel in the catalog is hundreds of compilations, and the
/// drive view did that twice per redraw — with a copy in progress, on every
/// progress tick. The app stopped answering while the copy itself ran fine.
///
/// These assert the property, not the clock: a pattern is compiled once.
final class RegexCacheTests: XCTestCase {
    /// Unique per test, so "was this compiled?" is not answered by something
    /// another test happened to warm up first.
    private func uniquePattern() -> String {
        "^isotope-\(UUID().uuidString)-(\\d+)\\.iso$"
    }

    func testAPatternIsCompiledOnceHoweverOftenItIsAskedFor() throws {
        let pattern = uniquePattern()
        let before = RegexCache.shared.compileCount
        for _ in 0..<500 { _ = try PatternMatcher(pattern) }
        XCTAssertEqual(RegexCache.shared.compileCount - before, 1)
    }

    func testCaseSensitivityIsPartOfTheIdentity() throws {
        let pattern = uniquePattern()
        let before = RegexCache.shared.compileCount
        _ = try PatternMatcher(pattern, caseInsensitive: false)
        _ = try PatternMatcher(pattern, caseInsensitive: true)
        _ = try PatternMatcher(pattern, caseInsensitive: true)
        // Two distinct matchers, two compiles — never one serving both.
        XCTAssertEqual(RegexCache.shared.compileCount - before, 2)
    }

    func testACachedMatcherStillMatches() throws {
        let name = "ubuntu-24.04.4-desktop-amd64.iso"
        let pattern = #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#
        _ = try PatternMatcher(pattern)
        let second = try PatternMatcher(pattern)
        XCTAssertEqual(second.capturedVersion(in: name), "24.04.4")
        XCTAssertTrue(second.matchesAnywhere(name))
        // Case-insensitivity is not leaked from one matcher to another.
        XCTAssertFalse(try PatternMatcher(pattern).matchesAnywhere(name.uppercased()))
        XCTAssertTrue(try PatternMatcher(pattern, caseInsensitive: true)
            .matchesAnywhere(name.uppercased()))
    }

    func testABrokenPatternThrowsEveryTimeAndIsNotRemembered() {
        let pattern = "([unclosed-\(UUID().uuidString)"
        let before = RegexCache.shared.compileCount
        for _ in 0..<3 {
            XCTAssertThrowsError(try PatternMatcher(pattern)) { error in
                XCTAssertEqual(error as? ProviderError, .invalidRegex(pattern))
            }
        }
        // Nothing was cached, so nothing was counted: the custom-source editor
        // compiles what the user is still typing.
        XCTAssertEqual(RegexCache.shared.compileCount - before, 0)
    }

    func testASecondPassOverTheCatalogCompilesNothing() throws {
        // The shape of the actual regression: the same detection, run again.
        let entries = (1...40).map { index in
            CatalogEntry(id: "entry-\(index)", name: "Entry \(index)", kind: .linux,
                         channels: [Channel(id: "a", name: "A", provider: .checksumFile(
                             url: URL(string: "https://example.invalid/SHA256SUMS")!,
                             filePattern: "^entry\(index)-(\\d+\\.\\d+)-amd64\\.iso$")),
                                    Channel(id: "b", name: "B", provider: .checksumFile(
                             url: URL(string: "https://example.invalid/SHA256SUMS")!,
                             filePattern: "^entry\(index)-(\\d+\\.\\d+)-arm64\\.iso$"))],
                         isBuiltIn: true)
        }
        let files = ["entry7-1.0-amd64.iso", "entry31-2.5-arm64.iso", "mystery.iso"]

        _ = ISOContentMatcher.detect(unclaimedFiles: files, in: entries)
        let afterFirst = RegexCache.shared.compileCount
        for _ in 0..<25 { _ = ISOContentMatcher.detect(unclaimedFiles: files, in: entries) }
        XCTAssertEqual(RegexCache.shared.compileCount, afterFirst,
                       "redrawing must not recompile the catalog")
    }
}
