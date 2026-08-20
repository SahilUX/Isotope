import XCTest
@testable import IsotopeCore

final class VersionTokenTests: XCTestCase {
    func testParsingSemanticVersions() {
        let cases: [(String, [Int])] = [
            ("24.04.3", [24, 4, 3]),
            ("41", [41]),
            ("12.7.0", [12, 7, 0]),
            ("22.04", [22, 4]),
            (" 6.1.2 ", [6, 1, 2]),
            ("2026.13.01", [2026, 13, 1]),   // month 13 → not a date
            ("2026.08.01.1", [2026, 8, 1, 1]) // four fields → not a date
        ]
        for (input, expected) in cases {
            guard case .semantic(let parts, let raw)? = VersionToken.parse(input) else {
                return XCTFail("\(input) did not parse as semantic")
            }
            XCTAssertEqual(parts, expected, "input: \(input)")
            XCTAssertEqual(raw, input.trimmingCharacters(in: .whitespaces))
        }
    }

    func testParsingDateVersions() {
        for input in ["2026.08.01", "2026-08-01", "1999.12.31"] {
            guard case .date? = VersionToken.parse(input) else {
                return XCTFail("\(input) did not parse as date")
            }
        }
    }

    func testParsingRejectsNonVersions() {
        for input in ["", "   ", "latest", "24.04-lts", "v24.04", "abc"] {
            XCTAssertNil(VersionToken.parse(input), "expected nil for \(input)")
        }
    }

    func testComparison() {
        let cases: [(String, String, ComparisonResult)] = [
            ("24.04.3", "24.04.1", .orderedDescending),
            ("24.04", "24.04.0", .orderedSame),
            ("24.10", "24.4", .orderedDescending),
            ("41", "40", .orderedDescending),
            ("12.7.0", "12.7", .orderedSame),
            ("9", "10", .orderedAscending),
            ("2026.08.01", "2026.08.02", .orderedAscending),
            ("2026-01-01", "2025-12-31", .orderedDescending)
        ]
        for (lhsRaw, rhsRaw, expected) in cases {
            guard let lhs = VersionToken.parse(lhsRaw), let rhs = VersionToken.parse(rhsRaw) else {
                return XCTFail("failed to parse \(lhsRaw)/\(rhsRaw)")
            }
            let actual: ComparisonResult = lhs < rhs ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
            XCTAssertEqual(actual, expected, "\(lhsRaw) vs \(rhsRaw)")
        }
    }

    func testEqualityAndHashingAgreeOnTrailingZeros() {
        let a = VersionToken.parse("24.04")!
        let b = VersionToken.parse("24.04.0")!
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testMixedKindsOrderDeterministically() {
        let semantic = VersionToken.parse("24.04.3")!
        let date = VersionToken.parse("2026.08.01")!
        XCTAssertTrue(semantic < date)
        XCTAssertFalse(date < semantic)
        XCTAssertNotEqual(semantic, date)
    }

    func testCodableRoundTrip() throws {
        let tokens = [VersionToken.parse("24.04.3")!, VersionToken.parse("2026.08.01")!]
        let data = try JSONStore.makeEncoder().encode(tokens)
        let decoded = try JSONStore.makeDecoder().decode([VersionToken].self, from: data)
        XCTAssertEqual(decoded, tokens)
        XCTAssertEqual(decoded.map(\.raw), tokens.map(\.raw))
    }

    // MARK: - Windows feature releases (PRD F43)

    func testParsingWindowsFeatureReleases() {
        let cases: [(String, Int, Int)] = [
            ("22H2", 22, 2), ("25H2", 25, 2), ("21H1", 21, 1),
            ("24H2", 24, 2), ("26H1", 26, 1), ("20H2", 20, 2),
            (" 25H2 ", 25, 2),
            ("25h2", 25, 2)   // lower-case "h" tolerated; raw is preserved as given
        ]
        for (input, year, half) in cases {
            guard case .windowsRelease(let parsedYear, let parsedHalf, let raw)?
                    = VersionToken.parse(input) else {
                return XCTFail("\(input) did not parse as a Windows feature release")
            }
            XCTAssertEqual(parsedYear, year, "input: \(input)")
            XCTAssertEqual(parsedHalf, half, "input: \(input)")
            XCTAssertEqual(raw, input.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The shapes that look like a release token but are not one must not become
    /// a version at all — a half-understood token is worse than none.
    func testParsingRejectsNearMissReleaseTokens() {
        for input in ["2H2", "225H2", "22H", "H2", "22H22", "1909", "22-H2"] {
            if case .windowsRelease? = VersionToken.parse(input) {
                XCTFail("\(input) must not parse as a Windows feature release")
            }
        }
    }

    /// The build number is still an ordinary semantic version — F43 changes what
    /// Windows *tracks*, not how a build number parses.
    func testBuildNumbersStillParseAsSemantic() {
        for (input, expected) in [("19045.7663", [19045, 7663]), ("26200.9168", [26200, 9168]),
                                  ("28000.2704", [28000, 2704])] {
            guard case .semantic(let parts, let raw)? = VersionToken.parse(input) else {
                return XCTFail("\(input) did not parse as semantic")
            }
            XCTAssertEqual(parts, expected)
            XCTAssertEqual(raw, input)
        }
    }

    func testFeatureReleaseOrdering() {
        let cases: [(String, String, ComparisonResult)] = [
            ("25H2", "22H2", .orderedDescending),
            ("22H2", "21H1", .orderedDescending),
            ("21H1", "21H2", .orderedAscending),
            ("26H1", "25H2", .orderedDescending),
            ("25H2", "25H2", .orderedSame),
            ("25h2", "25H2", .orderedSame)
        ]
        for (lhsRaw, rhsRaw, expected) in cases {
            guard let lhs = VersionToken.parse(lhsRaw), let rhs = VersionToken.parse(rhsRaw) else {
                return XCTFail("failed to parse \(lhsRaw)/\(rhsRaw)")
            }
            let actual: ComparisonResult = lhs < rhs
                ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
            XCTAssertEqual(actual, expected, "\(lhsRaw) vs \(rhsRaw)")
        }
    }

    /// The point of the separate case: "22H2" must never collide with "22.2" or
    /// with a build number, in equality or in a hashed collection.
    func testFeatureReleaseNeverCollidesWithOtherKinds() {
        let release = VersionToken.parse("22H2")!
        let lookalike = VersionToken.parse("22.2")!
        let build = VersionToken.parse("19045.7663")!
        let date = VersionToken.parse("2026-08-11")!
        XCTAssertNotEqual(release, lookalike)
        XCTAssertNotEqual(release, build)
        XCTAssertNotEqual(release, date)
        XCTAssertEqual(Set([release, lookalike, build, date]).count, 4)
        // Ordering stays total and deterministic across kinds, and antisymmetric.
        for other in [lookalike, build, date] {
            XCTAssertNotEqual(release < other, other < release)
        }
    }

    func testFeatureReleaseCodableRoundTrip() throws {
        let tokens = [VersionToken.parse("25H2")!, VersionToken.parse("22H2")!,
                      VersionToken.parse("19045.7663")!, VersionToken.parse("2026.08.01")!]
        let data = try JSONStore.makeEncoder().encode(tokens)
        let decoded = try JSONStore.makeDecoder().decode([VersionToken].self, from: data)
        XCTAssertEqual(decoded, tokens)
        XCTAssertEqual(decoded.map(\.raw), ["25H2", "22H2", "19045.7663", "2026.08.01"])
        XCTAssertTrue(decoded[1] < decoded[0])
    }
}
