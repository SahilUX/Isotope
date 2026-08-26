import Foundation
import IsotopeCore

/// PRD F63: how a transfer's speed and remaining time are written, in one place.
///
/// Every operation already measures both — `TransferRateEstimator` feeds them
/// through `TransferProgress` for downloads, drive copies and flashes alike —
/// but only the Activity list ever said so. The drive row, which is where a copy
/// is actually watched, showed a bar and a phase name and left "how long is
/// this going to take" unanswered.
enum TransferSummary {
    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// "12.3 MB/s", or nil before the estimator has a usable reading.
    static func rate(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0, bytesPerSecond.isFinite else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// "4 min left", or nil when there is nothing sensible to promise — no
    /// total, no rate, or a rate so unsteady the estimate would be fiction.
    static func remaining(_ eta: TimeInterval?) -> String? {
        guard let eta, eta.isFinite, eta > 0, let text = duration.string(from: eta) else { return nil }
        return "\(text) left"
    }

    /// "12.3 MB/s · 4 min left" — whichever parts are known, and nothing when
    /// neither is.
    static func rateAndRemaining(bytesPerSecond: Double?, eta: TimeInterval?) -> String? {
        let parts = [rate(bytesPerSecond), remaining(eta)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Copying to drive · 10%", or just the phase when there is no fraction to
    /// quote (an indeterminate download, a hash in progress).
    static func phaseAndPercent(_ phase: String, fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return phase }
        return "\(phase) · \(Int((fraction * 100).rounded()))%"
    }

    /// "1.2 GB of 8.47 GB", or just what is done when the total is unknown
    /// (a download with no `Content-Length`, a hash in progress).
    static func bytes(completed: Int64, total: Int64?) -> String {
        let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        guard let total, total > 0 else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
