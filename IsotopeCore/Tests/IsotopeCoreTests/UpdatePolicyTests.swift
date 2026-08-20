import XCTest
@testable import IsotopeCore

/// PRD §9 (v1.2): per-assignment update policy — migration, policy-aware
/// staleness and the relaxed duplicate rule (F33/F34/F36).
final class UpdatePolicyTests: XCTestCase {
    private func token(_ raw: String) -> VersionToken { VersionToken.parse(raw)! }

    // MARK: - Migration (F33)

    func testAssignmentsWrittenBeforeV12DecodeAsTrackLatest() throws {
        // Exactly the shape `drives.json` had in v1.1: no `updatePolicy` key.
        let json = """
        [{
          "id": "\(UUID().uuidString)",
          "volumeUUID": "UUID-A",
          "displayName": "VENTOY",
          "bookmark": "",
          "isoFolder": "",
          "keepOldVersions": false,
          "assignments": [
            { "id": "\(UUID().uuidString)", "entryID": "ubuntu", "channelID": "lts" },
            { "id": "\(UUID().uuidString)", "entryID": "fedora", "channelID": "workstation",
              "installed": { "fileName": "Fedora-41.iso", "placedByApp": true,
                             "updatedAt": "2026-01-02T03:04:05Z" } }
          ]
        }]
        """
        let drives = try JSONStore.loadJSON([ManagedDrive].self, from: Data(json.utf8))

        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(drives[0].assignments.count, 2)
        XCTAssertTrue(drives[0].assignments.allSatisfy { $0.updatePolicy == .trackLatest })
        XCTAssertFalse(drives[0].assignments[0].isPinned)
        XCTAssertEqual(drives[0].assignments[1].installed?.fileName, "Fedora-41.iso")
    }

    func testPolicySurvivesARoundTrip() throws {
        let drive = ManagedDrive(volumeUUID: "UUID-A", displayName: "VENTOY", bookmark: Data(),
                                 assignments: [
                                    Assignment(entryID: "ubuntu", channelID: "lts"),
                                    Assignment(entryID: "ubuntu", channelID: "lts",
                                               updatePolicy: .keepAsIs)
                                 ])
        let data = try JSONStore.makeEncoder().encode([drive])
        let decoded = try JSONStore.loadJSON([ManagedDrive].self, from: data)

        XCTAssertEqual(decoded[0].assignments.map(\.updatePolicy), [.trackLatest, .keepAsIs])
    }

    // MARK: - Policy-aware staleness (F33/F36)

    func testPolicyTable() {
        let release = Release(version: token("24.04.4"), fileName: "ubuntu-24.04.4-desktop-amd64.iso")
        let old = InstalledISO(fileName: "ubuntu-22.04.1-desktop-amd64.iso",
                               version: token("22.04.1"), placedByApp: true)
        let current = InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                   version: token("24.04.4"), placedByApp: true)
        let unrecognised = InstalledISO(fileName: "mystery.iso", version: nil, placedByApp: false)

        let cases: [(installed: InstalledISO?, latest: Release?, policy: UpdatePolicy,
                     expected: Staleness)] = [
            (old, release, .trackLatest, .stale),
            (old, release, .keepAsIs, .pinned),
            (current, release, .trackLatest, .upToDate),
            (current, release, .keepAsIs, .pinned),
            (nil, release, .trackLatest, .notInstalled),
            (nil, release, .keepAsIs, .pinned),
            (unrecognised, release, .trackLatest, .unknown),
            (unrecognised, release, .keepAsIs, .pinned),
            (old, nil, .trackLatest, .unknown),
            (old, nil, .keepAsIs, .pinned),
        ]
        for (installed, latest, policy, expected) in cases {
            let assignment = Assignment(entryID: "ubuntu", channelID: "lts",
                                        installed: installed, updatePolicy: policy)
            XCTAssertEqual(Staleness.evaluate(assignment: assignment, latest: latest), expected,
                           "\(installed?.fileName ?? "nil") · \(policy.rawValue)")
        }
    }

    func testPinnedNeverCountsAsAnUpdate() {
        XCTAssertFalse(Staleness.pinned.needsUpdate)
    }

    func testUnpinningReEvaluatesImmediately() {
        let release = Release(version: token("24.04.4"), fileName: "ubuntu-24.04.4-desktop-amd64.iso")
        var assignment = Assignment(entryID: "ubuntu", channelID: "lts",
                                    installed: InstalledISO(fileName: "ubuntu-22.04.1-desktop-amd64.iso",
                                                            version: token("22.04.1"), placedByApp: true),
                                    updatePolicy: .keepAsIs)
        XCTAssertEqual(Staleness.evaluate(assignment: assignment, latest: release), .pinned)
        assignment.updatePolicy = .trackLatest
        XCTAssertEqual(Staleness.evaluate(assignment: assignment, latest: release), .stale)
    }

    // MARK: - Duplicate rule (F34)

    private func assignment(_ entry: String, _ channel: String, _ policy: UpdatePolicy) -> Assignment {
        Assignment(entryID: entry, channelID: channel, updatePolicy: policy)
    }

    func testCanAddTable() {
        let tracker = assignment("ubuntu", "lts", .trackLatest)
        let pinned = assignment("ubuntu", "lts", .keepAsIs)
        let otherChannel = assignment("ubuntu", "latest", .trackLatest)

        let cases: [(existing: [Assignment], policy: UpdatePolicy, expected: Bool, note: String)] = [
            ([], .trackLatest, true, "empty drive"),
            ([], .keepAsIs, true, "empty drive, pinned"),
            ([otherChannel], .trackLatest, true, "another channel of the same entry"),
            ([tracker], .trackLatest, false, "a second tracker of one channel is refused"),
            ([tracker], .keepAsIs, true, "a pinned copy beside the tracker is allowed"),
            ([pinned], .trackLatest, true, "a tracker beside a pinned copy is allowed"),
            ([pinned], .keepAsIs, true, "any number of pinned copies"),
            ([pinned, pinned], .trackLatest, true, "still only one tracker in play"),
            ([pinned, tracker], .trackLatest, false, "the tracker is already there"),
        ]
        for (existing, policy, expected, note) in cases {
            XCTAssertEqual(AssignmentRules.canAdd(entryID: "ubuntu", channelID: "lts",
                                                  policy: policy, to: existing),
                           expected, note)
        }
    }

    func testCanSetPolicyOnlyRefusesASecondTracker() {
        let tracker = assignment("ubuntu", "lts", .trackLatest)
        let pinned = assignment("ubuntu", "lts", .keepAsIs)
        let all = [tracker, pinned]

        // Pinning is always allowed…
        XCTAssertTrue(AssignmentRules.canSetPolicy(.keepAsIs, forAssignmentID: tracker.id, in: all))
        // …un-pinning only while nothing else tracks that channel.
        XCTAssertFalse(AssignmentRules.canSetPolicy(.trackLatest, forAssignmentID: pinned.id, in: all))
        XCTAssertTrue(AssignmentRules.canSetPolicy(.trackLatest, forAssignmentID: pinned.id,
                                                   in: [pinned]))
        // A tracker may be "set" to what it already is.
        XCTAssertTrue(AssignmentRules.canSetPolicy(.trackLatest, forAssignmentID: tracker.id, in: all))
        // An unknown assignment is not in the drive at all.
        XCTAssertFalse(AssignmentRules.canSetPolicy(.keepAsIs, forAssignmentID: UUID(), in: all))
    }
}
