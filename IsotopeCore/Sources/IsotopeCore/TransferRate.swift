import Foundation

/// Speed and ETA for a download or a copy (PRD F19).
///
/// A plain "total bytes ÷ total elapsed" average lags badly on a connection that
/// changes speed, and an instantaneous sample jitters. This is an exponentially
/// weighted moving average over the deltas between progress callbacks, which is
/// steady enough to display and cheap enough to update per chunk.
public struct TransferRateEstimator: Sendable, Equatable {
    /// Weight of the newest sample; the rest decays. 0.25 settles in ~10 samples.
    public var smoothing: Double
    /// Samples closer together than this are accumulated rather than measured,
    /// so a burst of tiny chunks does not produce an absurd rate.
    public var minimumSampleInterval: TimeInterval

    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0
    private var pendingBytes: Int64 = 0
    private var average: Double?

    public init(smoothing: Double = 0.25, minimumSampleInterval: TimeInterval = 0.25) {
        self.smoothing = smoothing
        self.minimumSampleInterval = minimumSampleInterval
    }

    /// `totalBytes` is cumulative bytes transferred so far, not a delta.
    public mutating func record(totalBytes: Int64, at date: Date) {
        guard let last = lastSampleAt else {
            lastSampleAt = date
            lastSampleBytes = totalBytes
            return
        }
        pendingBytes += max(0, totalBytes - lastSampleBytes)
        lastSampleBytes = totalBytes
        let elapsed = date.timeIntervalSince(last)
        guard elapsed >= minimumSampleInterval else { return }
        let sample = Double(pendingBytes) / elapsed
        average = average.map { $0 + smoothing * (sample - $0) } ?? sample
        pendingBytes = 0
        lastSampleAt = date
    }

    /// Nil until at least one interval has been measured.
    public var bytesPerSecond: Double? {
        guard let average, average > 0 else { return nil }
        return average
    }

    public func eta(remainingBytes: Int64) -> TimeInterval? {
        guard remainingBytes > 0, let rate = bytesPerSecond else { return nil }
        return Double(remainingBytes) / rate
    }
}

/// Snapshot handed to the UI for one in-flight transfer.
public struct TransferProgress: Sendable, Equatable, Hashable {
    public var completedBytes: Int64
    /// Nil when the server sends no `Content-Length`.
    public var totalBytes: Int64?
    public var bytesPerSecond: Double?
    public var eta: TimeInterval?

    public init(completedBytes: Int64, totalBytes: Int64? = nil,
                bytesPerSecond: Double? = nil, eta: TimeInterval? = nil) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.eta = eta
    }

    /// Nil total → indeterminate progress, which the UI shows as a spinner.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}
