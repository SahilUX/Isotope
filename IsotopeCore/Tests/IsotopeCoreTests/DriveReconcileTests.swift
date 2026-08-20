import XCTest
@testable import IsotopeCore

/// PRD F7 — reconciliation runs entirely off a fake file listing (DESIGN §7),
/// so none of these tests need a real USB drive.
final class DriveReconcileTests: XCTestCase {
    private let ubuntuPattern = #"ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso"#
    private let fedoraPattern = #"Fedora-Workstation-Live-.*-(\d+)-.*\.iso"#

    private func input(pattern: String? = nil,
                       releaseFileName: String? = nil,
                       releaseVersion: String? = nil,
                       installed: InstalledISO? = nil) -> ReconcileInput {
        ReconcileInput(assignmentID: UUID(),
                       fileNamePattern: pattern,
                       releaseFileName: releaseFileName,
                       releaseVersion: releaseVersion.flatMap(VersionToken.parse),
                       installed: installed)
    }

    // MARK: - File listing filter

    func testOnlyVisibleISOFilesAreConsidered() throws {
        let names = ["ubuntu-24.04.1-desktop-amd64.iso", "._ubuntu-24.04.1-desktop-amd64.iso",
                     ".hidden.iso", "notes.txt", "ventoy", "UPPER.ISO", ".iso"]
        XCTAssertEqual(DriveScan.isoFileNames(in: names),
                       ["ubuntu-24.04.1-desktop-amd64.iso", "UPPER.ISO"])
    }

    // MARK: - Recognition

    func testRecognisesInstalledISOByPattern() throws {
        let assignment = input(pattern: ubuntuPattern)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.1-desktop-amd64.iso", "ventoy.json"],
            assignments: [assignment])

        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .discovered)
        XCTAssertEqual(outcome.installed?.fileName, "ubuntu-24.04.1-desktop-amd64.iso")
        XCTAssertEqual(outcome.installed?.version, VersionToken.parse("24.04.1"))
        // Discovered files were not written by Isotope (PRD F7/F22).
        XCTAssertEqual(outcome.installed?.placedByApp, false)
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testHighestVersionWinsWhenSeveralMatch() throws {
        let assignment = input(pattern: ubuntuPattern)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.1-desktop-amd64.iso",
                        "ubuntu-24.04.3-desktop-amd64.iso",
                        "ubuntu-22.04.5-desktop-amd64.iso"],
            assignments: [assignment])

        XCTAssertEqual(result.outcome(for: assignment.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
        // The losers are reported informationally, never deleted.
        XCTAssertEqual(result.unknownFiles, ["ubuntu-22.04.5-desktop-amd64.iso",
                                             "ubuntu-24.04.1-desktop-amd64.iso"])
    }

    func testUnchangedWhenRecordedFileIsStillPresent() throws {
        let recorded = InstalledISO(fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                    version: VersionToken.parse("24.04.3"),
                                    placedByApp: true,
                                    updatedAt: Date(timeIntervalSince1970: 1_000))
        let assignment = input(pattern: ubuntuPattern, installed: recorded)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.3-desktop-amd64.iso"], assignments: [assignment])

        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .unchanged)
        // Provenance and timestamp survive a rescan.
        XCTAssertEqual(outcome.installed?.placedByApp, true)
        XCTAssertEqual(outcome.installed?.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testMissingFileClearsInstalledAndReportsPreviousName() throws {
        let recorded = InstalledISO(fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                    version: VersionToken.parse("24.04.3"), placedByApp: true)
        let assignment = input(pattern: ubuntuPattern, installed: recorded)
        let result = DriveReconciler.reconcile(fileNames: ["memtest86+.iso"], assignments: [assignment])

        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .missing)
        XCTAssertNil(outcome.installed)
        XCTAssertEqual(outcome.previousFileName, "ubuntu-24.04.3-desktop-amd64.iso")
        XCTAssertEqual(result.unknownFiles, ["memtest86+.iso"])
        XCTAssertEqual(result.changes.count, 1)
    }

    func testAbsentWhenNothingRecordedAndNothingMatches() throws {
        let assignment = input(pattern: ubuntuPattern)
        let result = DriveReconciler.reconcile(fileNames: [], assignments: [assignment])
        XCTAssertEqual(result.outcome(for: assignment.assignmentID)?.change, .absent)
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testUnknownFilesAreSurfacedNotClaimed() throws {
        let assignment = input(pattern: ubuntuPattern)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.3-desktop-amd64.iso", "arch.iso", "Win11_24H2.iso"],
            assignments: [assignment])
        XCTAssertEqual(result.unknownFiles, ["arch.iso", "Win11_24H2.iso"])
    }

    // MARK: - Exact release filename path

    func testExactReleaseFilenameMatchesWithoutAPattern() throws {
        // jsonFeed/staticURL sources expose no filename regex; the cached
        // release's filename is the only handle we have.
        let assignment = input(releaseFileName: "pop-os_22.04_amd64_intel_35.iso",
                               releaseVersion: "22.04")
        let result = DriveReconciler.reconcile(
            fileNames: ["pop-os_22.04_amd64_intel_35.iso"], assignments: [assignment])

        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .discovered)
        XCTAssertEqual(outcome.installed?.version, VersionToken.parse("22.04"))
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testEmptyReleaseFilenameNeverMatches() throws {
        // Windows 11's cached release has an empty fileName and no ISO URL —
        // it must never claim a file, least of all an empty-named one.
        let assignment = input(releaseFileName: "", releaseVersion: "26100")
        let result = DriveReconciler.reconcile(
            fileNames: ["Win11_24H2_English_x64.iso"], assignments: [assignment])

        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .absent)
        XCTAssertNil(outcome.installed)
        XCTAssertEqual(result.unknownFiles, ["Win11_24H2_English_x64.iso"])
    }

    func testRecordedFileSurvivesWhenPatternNoLongerMatches() throws {
        // Hand-placed ISO with an off-pattern name: pass 3 keeps it recorded
        // rather than reporting a spurious "missing".
        let recorded = InstalledISO(fileName: "my-ubuntu-copy.iso", placedByApp: false)
        let assignment = input(pattern: ubuntuPattern, installed: recorded)
        let result = DriveReconciler.reconcile(fileNames: ["my-ubuntu-copy.iso"],
                                               assignments: [assignment])
        XCTAssertEqual(result.outcome(for: assignment.assignmentID)?.change, .unchanged)
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    // MARK: - Multiple assignments

    func testEachFileIsClaimedByAtMostOneAssignment() throws {
        let ubuntu = input(pattern: ubuntuPattern)
        let fedora = input(pattern: fedoraPattern)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.3-desktop-amd64.iso",
                        "Fedora-Workstation-Live-x86_64-41-1.4.iso"],
            assignments: [ubuntu, fedora])

        XCTAssertEqual(result.outcome(for: ubuntu.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
        XCTAssertEqual(result.outcome(for: fedora.assignmentID)?.installed?.version,
                       VersionToken.parse("41"))
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testExactReleaseMatchWinsOverAnEarlierPatternMatch() throws {
        // Ubuntu LTS and Latest share a filename shape; the channel whose
        // resolved release names the file exactly gets it.
        let lts = input(pattern: ubuntuPattern)
        let latest = input(pattern: ubuntuPattern, releaseFileName: "ubuntu-25.04-desktop-amd64.iso",
                           releaseVersion: "25.04")
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.3-desktop-amd64.iso", "ubuntu-25.04-desktop-amd64.iso"],
            assignments: [lts, latest])

        XCTAssertEqual(result.outcome(for: latest.assignmentID)?.installed?.fileName,
                       "ubuntu-25.04-desktop-amd64.iso")
        XCTAssertEqual(result.outcome(for: lts.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
    }

    // MARK: - Two assignments of one entry+channel (PRD F34)

    func testTrackingAndPinnedCopiesOfOneChannelKeepTheirOwnFiles() throws {
        // The tracker holds 24.04.4, the pinned copy 22.04.5, and the resolved
        // release is a version neither of them has yet: nothing matches by
        // filename, so the regex pass has to respect recorded ownership.
        let tracking = input(pattern: ubuntuPattern,
                             releaseFileName: "ubuntu-25.04-desktop-amd64.iso",
                             releaseVersion: "25.04",
                             installed: InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                                     version: VersionToken.parse("24.04.4"),
                                                     placedByApp: true))
        let pinned = input(pattern: ubuntuPattern,
                           releaseFileName: "ubuntu-25.04-desktop-amd64.iso",
                           releaseVersion: "25.04",
                           installed: InstalledISO(fileName: "ubuntu-22.04.5-desktop-amd64.iso",
                                                   version: VersionToken.parse("22.04.5"),
                                                   placedByApp: true))
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.4-desktop-amd64.iso", "ubuntu-22.04.5-desktop-amd64.iso"],
            assignments: [tracking, pinned])

        XCTAssertEqual(result.outcome(for: tracking.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.installed?.fileName,
                       "ubuntu-22.04.5-desktop-amd64.iso")
        XCTAssertTrue(result.outcomes.allSatisfy { $0.change == .unchanged })
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testTheTrackerCannotStealThePinnedCopysFileEvenWhenItIsTheHighestVersion() throws {
        // The tracker's regex matches the pinned copy, which here is *newer*
        // than the tracker's own file — "highest version wins" would hand it
        // over and leave the pinned assignment reported missing.
        let tracking = input(pattern: ubuntuPattern,
                             installed: InstalledISO(fileName: "ubuntu-22.04.5-desktop-amd64.iso",
                                                     version: VersionToken.parse("22.04.5"),
                                                     placedByApp: true))
        let pinned = input(pattern: ubuntuPattern,
                           installed: InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                                   version: VersionToken.parse("24.04.4"),
                                                   placedByApp: true))
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-22.04.5-desktop-amd64.iso", "ubuntu-24.04.4-desktop-amd64.iso"],
            assignments: [tracking, pinned])

        XCTAssertEqual(result.outcome(for: tracking.assignmentID)?.installed?.fileName,
                       "ubuntu-22.04.5-desktop-amd64.iso")
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testTheReleaseFileNameDoesNotOverrideAnotherAssignmentsRecordedFile() throws {
        // The pinned copy happens to hold exactly the file the tracker's release
        // names. Recorded ownership still wins, and the tracker — whose own file
        // is gone — reports missing rather than claiming the pinned one.
        let tracking = input(pattern: ubuntuPattern,
                             releaseFileName: "ubuntu-24.04.4-desktop-amd64.iso",
                             releaseVersion: "24.04.4",
                             installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                     version: VersionToken.parse("24.04.1"),
                                                     placedByApp: true))
        let pinned = input(pattern: ubuntuPattern,
                           installed: InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                                   version: VersionToken.parse("24.04.4"),
                                                   placedByApp: true))
        let result = DriveReconciler.reconcile(fileNames: ["ubuntu-24.04.4-desktop-amd64.iso"],
                                               assignments: [tracking, pinned])

        XCTAssertEqual(result.outcome(for: tracking.assignmentID)?.change, .missing)
        XCTAssertNil(result.outcome(for: tracking.assignmentID)?.installed)
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.change, .unchanged)
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    func testANewFileNobodyRecordsIsStillDiscoveredByTheTracker() throws {
        // Reserving recorded files must not block the normal case: a hand-placed
        // upgrade nobody records goes to the tracker, and the pinned copy stays.
        let tracking = input(pattern: ubuntuPattern,
                             installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                     version: VersionToken.parse("24.04.1"),
                                                     placedByApp: true))
        let pinned = input(pattern: ubuntuPattern,
                           installed: InstalledISO(fileName: "ubuntu-22.04.5-desktop-amd64.iso",
                                                   version: VersionToken.parse("22.04.5"),
                                                   placedByApp: true))
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.4-desktop-amd64.iso", "ubuntu-22.04.5-desktop-amd64.iso"],
            assignments: [tracking, pinned])

        XCTAssertEqual(result.outcome(for: tracking.assignmentID)?.change, .discovered)
        XCTAssertEqual(result.outcome(for: tracking.assignmentID)?.installed?.fileName,
                       "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.installed?.fileName,
                       "ubuntu-22.04.5-desktop-amd64.iso")
        XCTAssertTrue(result.unknownFiles.isEmpty)
    }

    /// PRD F33: a pin is about one file. A newer copy nobody else claims must
    /// not become the pinned assignment's installed ISO.
    func testAPinnedAssignmentKeepsItsFileEvenWhenANewerOneIsUnclaimed() throws {
        let pinned = ReconcileInput(assignmentID: UUID(),
                                    fileNamePattern: ubuntuPattern,
                                    releaseFileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                    releaseVersion: VersionToken.parse("24.04.4"),
                                    installed: InstalledISO(fileName: "ubuntu-22.04.5-desktop-amd64.iso",
                                                            version: VersionToken.parse("22.04.5"),
                                                            placedByApp: false),
                                    isPinned: true)
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.4-desktop-amd64.iso", "ubuntu-22.04.5-desktop-amd64.iso"],
            assignments: [pinned])

        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.change, .unchanged)
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.installed?.fileName,
                       "ubuntu-22.04.5-desktop-amd64.iso")
        // The newer file stays unclaimed, so F41 can offer it.
        XCTAssertEqual(result.unknownFiles, ["ubuntu-24.04.4-desktop-amd64.iso"])
    }

    /// A pin with nothing installed yet still matches normally — there is no
    /// file to keep.
    func testAPinnedAssignmentWithNothingInstalledStillDiscovers() throws {
        let pinned = ReconcileInput(assignmentID: UUID(), fileNamePattern: ubuntuPattern,
                                    isPinned: true)
        let result = DriveReconciler.reconcile(fileNames: ["ubuntu-24.04.1-desktop-amd64.iso"],
                                               assignments: [pinned])
        XCTAssertEqual(result.outcome(for: pinned.assignmentID)?.change, .discovered)
    }

    /// PRD F43 migration: an assignment adopted before the Windows patterns
    /// captured `NNHN` holds the right file with no version. The next scan must
    /// re-parse it in place — nothing about the file moved, so no other pass
    /// would ever touch it, and staleness would stay "Unknown" for ever.
    func testAVersionlessRecordIsReparsedInPlace() throws {
        let windowsPattern = #"^Win11(?:_(\d{2}H\d)|_\d{4})?_[A-Za-z]+(?:[ _-][A-Za-z]+)*_(?:x64|x32|x86|arm64)(?:_?v\d+)?\.iso$"#
        let adopted = InstalledISO(fileName: "Win11_25H2_English_x64_v2.iso", version: nil,
                                   placedByApp: false,
                                   updatedAt: Date(timeIntervalSince1970: 1_000))
        let assignment = ReconcileInput(assignmentID: UUID(), fileNamePattern: windowsPattern,
                                        installed: adopted)
        let result = DriveReconciler.reconcile(fileNames: ["Win11_25H2_English_x64_v2.iso"],
                                               assignments: [assignment])
        let outcome = try XCTUnwrap(result.outcome(for: assignment.assignmentID))
        XCTAssertEqual(outcome.change, .unchanged, "the file did not move")
        XCTAssertEqual(outcome.installed?.version, .windowsRelease(year: 25, half: 2, raw: "25H2"))
        // Provenance and timestamp are untouched: this is a re-parse, not a find.
        XCTAssertEqual(outcome.installed?.placedByApp, false)
        XCTAssertEqual(outcome.installed?.updatedAt, adopted.updatedAt)
    }

    /// And a record that already has a version is left exactly as it is, even
    /// when the pattern would parse the name differently.
    func testAnExistingVersionIsNeverOverwritten() throws {
        let existing = InstalledISO(fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                    version: VersionToken.parse("24.04.1"), placedByApp: true,
                                    updatedAt: Date(timeIntervalSince1970: 2_000))
        let assignment = ReconcileInput(assignmentID: UUID(), fileNamePattern: ubuntuPattern,
                                        installed: existing)
        let result = DriveReconciler.reconcile(fileNames: ["ubuntu-24.04.3-desktop-amd64.iso"],
                                               assignments: [assignment])
        XCTAssertEqual(result.outcome(for: assignment.assignmentID)?.installed, existing)
    }

    /// A name that still parses to nothing stays versionless rather than
    /// acquiring a fabricated one.
    func testAnUnparseableNameStaysVersionless() throws {
        let windowsPattern = #"^Win10(?:_(\d{2}H\d)|_\d{4})?_[A-Za-z]+_(?:x64|x86)\.iso$"#
        let adopted = InstalledISO(fileName: "Win10_1909_English_x64.iso", version: nil,
                                   placedByApp: false)
        let assignment = ReconcileInput(assignmentID: UUID(), fileNamePattern: windowsPattern,
                                        installed: adopted)
        let result = DriveReconciler.reconcile(fileNames: ["Win10_1909_English_x64.iso"],
                                               assignments: [assignment])
        XCTAssertNil(result.outcome(for: assignment.assignmentID)?.installed?.version)
    }

    func testInvalidRegexDegradesToNoPattern() throws {
        let assignment = input(pattern: "ubuntu-([0-9]+")
        let result = DriveReconciler.reconcile(fileNames: ["ubuntu-24.04.3-desktop-amd64.iso"],
                                               assignments: [assignment])
        XCTAssertEqual(result.outcome(for: assignment.assignmentID)?.change, .absent)
        XCTAssertEqual(result.unknownFiles, ["ubuntu-24.04.3-desktop-amd64.iso"])
    }
}
