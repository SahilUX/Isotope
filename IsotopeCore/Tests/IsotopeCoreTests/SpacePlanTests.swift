import XCTest
@testable import IsotopeCore

/// PRD F18 pre-flight arithmetic and DESIGN §6's "drive full even after
/// reclaiming the old ISO → exact shortfall".
final class SpacePlanTests: XCTestCase {
    private let gb: Int64 = 1024 * 1024 * 1024

    func testDefaultMarginScalesWithTheFileAndCapsAt64MB() {
        XCTAssertEqual(SpacePlan.margin(forRequired: 5 * gb), 64 * 1024 * 1024)
        XCTAssertEqual(SpacePlan.margin(forRequired: 20 * 1024 * 1024), 1024 * 1024)
        XCTAssertEqual(SpacePlan.margin(forRequired: 0), 0)
        // A 12 MB file does not get asked for 64 MB of headroom.
        let tight = SpacePlan(requiredBytes: 12 * 1024 * 1024, availableBytes: 10 * 1024 * 1024,
                              reclaimableBytes: 8 * 1024 * 1024)
        XCTAssertTrue(tight.fits)
        XCTAssertTrue(tight.requiresReclaimFirst)
    }

    func testFitsWithRoomToSpare() {
        let plan = SpacePlan(requiredBytes: 4 * gb, availableBytes: 30 * gb)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.shortfallBytes, 0)
        XCTAssertFalse(plan.requiresReclaimFirst)
    }

    func testShortfallIsExactAndIncludesTheSafetyMargin() {
        let plan = SpacePlan(requiredBytes: 10 * gb, availableBytes: 6 * gb,
                             reclaimableBytes: 0, marginBytes: 0)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.shortfallBytes, 4 * gb)

        let withMargin = SpacePlan(requiredBytes: 10 * gb, availableBytes: 10 * gb,
                                   reclaimableBytes: 0, marginBytes: 64 * 1024 * 1024)
        XCTAssertEqual(withMargin.shortfallBytes, 64 * 1024 * 1024)
    }

    func testReclaimableOldISOCountsTowardsAvailableSpace() {
        // 6 GB free, a 5 GB ISO being replaced, a 10 GB replacement: it fits,
        // but only if the old file goes first.
        let plan = SpacePlan(requiredBytes: 10 * gb, availableBytes: 6 * gb,
                             reclaimableBytes: 5 * gb, marginBytes: 0)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.effectiveAvailableBytes, 11 * gb)
        XCTAssertTrue(plan.requiresReclaimFirst)
    }

    func testKeepingOldVersionsRemovesTheReclaimAndCanFail() {
        // PRD F6 "keep old versions" → nothing is reclaimable.
        let plan = SpacePlan(requiredBytes: 10 * gb, availableBytes: 6 * gb,
                             reclaimableBytes: 0, marginBytes: 0)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.shortfallBytes, 4 * gb)
        XCTAssertFalse(plan.requiresReclaimFirst)
    }

    func testNoReclaimNeededWhenItAlreadyFitsWithoutDeleting() {
        let plan = SpacePlan(requiredBytes: 2 * gb, availableBytes: 20 * gb,
                             reclaimableBytes: 5 * gb, marginBytes: 0)
        XCTAssertFalse(plan.requiresReclaimFirst)
    }

    func testNegativeInputsAreClamped() {
        let plan = SpacePlan(requiredBytes: 1 * gb, availableBytes: 0,
                             reclaimableBytes: -5, marginBytes: -1)
        XCTAssertEqual(plan.reclaimableBytes, 0)
        XCTAssertEqual(plan.marginBytes, 0)
        XCTAssertEqual(plan.shortfallBytes, gb)
    }
}

/// PRD F19 progress readout.
final class TransferRateTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testRateIsUnknownUntilAnIntervalHasBeenMeasured() {
        var estimator = TransferRateEstimator()
        estimator.record(totalBytes: 0, at: epoch)
        XCTAssertNil(estimator.bytesPerSecond)
        XCTAssertNil(estimator.eta(remainingBytes: 1000))
    }

    func testMeasuresASteadyRateAndProjectsAnETA() {
        var estimator = TransferRateEstimator(smoothing: 1, minimumSampleInterval: 0.5)
        estimator.record(totalBytes: 0, at: epoch)
        estimator.record(totalBytes: 1_000_000, at: epoch.addingTimeInterval(1))
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 1_000_000, accuracy: 1)
        XCTAssertEqual(estimator.eta(remainingBytes: 5_000_000) ?? 0, 5, accuracy: 0.01)
    }

    func testSamplesCloserThanTheMinimumIntervalAreAccumulatedNotMeasured() {
        var estimator = TransferRateEstimator(smoothing: 1, minimumSampleInterval: 1)
        estimator.record(totalBytes: 0, at: epoch)
        // Four 250 KB chunks inside one second: no bogus multi-GB/s reading.
        for step in 1...4 {
            estimator.record(totalBytes: Int64(step) * 250_000,
                             at: epoch.addingTimeInterval(Double(step) * 0.1))
        }
        XCTAssertNil(estimator.bytesPerSecond)
        estimator.record(totalBytes: 1_000_000, at: epoch.addingTimeInterval(1))
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 1_000_000, accuracy: 1)
    }

    func testSmoothingDampsASuddenSpeedChange() {
        var estimator = TransferRateEstimator(smoothing: 0.25, minimumSampleInterval: 0.5)
        estimator.record(totalBytes: 0, at: epoch)
        estimator.record(totalBytes: 1_000_000, at: epoch.addingTimeInterval(1))
        estimator.record(totalBytes: 11_000_000, at: epoch.addingTimeInterval(2))
        let rate = estimator.bytesPerSecond ?? 0
        XCTAssertGreaterThan(rate, 1_000_000)
        XCTAssertLessThan(rate, 10_000_000)
    }

    func testFractionCompletedIsNilWithoutAKnownTotal() {
        XCTAssertNil(TransferProgress(completedBytes: 500).fractionCompleted)
        XCTAssertEqual(TransferProgress(completedBytes: 500, totalBytes: 1000).fractionCompleted, 0.5)
        // A server that under-reports Content-Length must not push progress past 1.
        XCTAssertEqual(TransferProgress(completedBytes: 2000, totalBytes: 1000).fractionCompleted, 1)
    }
}
