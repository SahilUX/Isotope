import Foundation

// MARK: - Catalog rule (PRD F73)

/// PRD F73: where else the same file can be fetched from. A resolved ISO URL
/// that starts with `from` has an alternate for each `to`, made by swapping the
/// prefix — `https://releases.ubuntu.com/26.04/x.iso` with
/// `{"from": "https://releases.ubuntu.com/", "to": ["https://mirrors.kernel.org/ubuntu-releases/"]}`
/// also lives at `https://mirrors.kernel.org/ubuntu-releases/26.04/x.iso`.
///
/// A prefix swap rather than a list of hostnames, because mirrors rarely keep
/// the origin's path: Ubuntu's `/26.04/` is `/ubuntu-releases/26.04/` on
/// kernel.org. Nothing here is trusted beyond "might be faster": the checksum
/// still comes from the origin and is still verified after the download.
public struct MirrorRule: Codable, Hashable, Sendable {
    public var from: String
    public var to: [String]

    public init(from: String, to: [String]) {
        self.from = from
        self.to = to
    }
}

public enum MirrorCandidates {
    /// Every URL `url` can be downloaded from: the original first, then each
    /// rewrite in rule order, de-duplicated. Only https alternates survive — a
    /// mirror is somebody else's server, and the download should not be easier
    /// to tamper with than the origin. (The checksum would catch it; the point
    /// is not to need it.) The original is kept whatever its scheme, because it
    /// is what the catalog resolved and dropping it would mean no download.
    public static func candidates(for url: URL, rules: [MirrorRule]) -> [URL] {
        let original = url.absoluteString
        var result = [url]
        var seen: Set<String> = [original]
        for rule in rules where !rule.from.isEmpty && original.hasPrefix(rule.from) {
            let rest = original.dropFirst(rule.from.count)
            for prefix in rule.to {
                guard let candidate = URL(string: prefix + rest),
                      candidate.scheme?.lowercased() == "https",
                      candidate.host?.isEmpty == false
                else { continue }
                if seen.insert(candidate.absoluteString).inserted { result.append(candidate) }
            }
        }
        return result
    }
}

// MARK: - Probing (PRD F73)

/// What one 1 MiB range request against a candidate came back with. Built by
/// the app's prober; judged here, so the judgement is testable offline.
public struct MirrorProbeResult: Sendable, Hashable {
    public var url: URL
    /// Nil when no response arrived at all (timeout, refused, cancelled).
    public var statusCode: Int?
    /// The total from `Content-Range: bytes 0-1048575/<total>`.
    public var contentRangeTotal: Int64?
    public var bytesReceived: Int64
    /// Wall time from issuing the request to the last byte read, connection
    /// setup included — that latency is exactly what the download will feel.
    public var elapsed: TimeInterval

    public init(url: URL, statusCode: Int?, contentRangeTotal: Int64? = nil,
                bytesReceived: Int64 = 0, elapsed: TimeInterval = 0) {
        self.url = url
        self.statusCode = statusCode
        self.contentRangeTotal = contentRangeTotal
        self.bytesReceived = bytesReceived
        self.elapsed = elapsed
    }

    public static func failed(_ url: URL, elapsed: TimeInterval = 0) -> MirrorProbeResult {
        MirrorProbeResult(url: url, statusCode: nil, elapsed: elapsed)
    }

    /// Answered the range request with part of a file. Says nothing yet about
    /// whether it is the *right* file; that is `MirrorRanking`'s call.
    public var answeredRange: Bool { statusCode == 206 && bytesReceived > 0 }

    public var bytesPerSecond: Double? {
        guard bytesReceived > 0, elapsed > 0 else { return nil }
        return Double(bytesReceived) / elapsed
    }
}

/// How long probing may take. Each probe is bounded on its own, and once the
/// first good answer is in, the rest get a grace period proportional to it —
/// a mirror that takes three times as long to send 1 MiB is not going to win,
/// so there is no point making the user wait for it.
public struct MirrorProbeLimits: Sendable, Hashable {
    public var requestedBytes: Int64
    public var perProbeTimeout: TimeInterval
    public var graceMultiplier: Double
    public var graceFloor: TimeInterval

    public init(requestedBytes: Int64 = 1 << 20, perProbeTimeout: TimeInterval = 6,
                graceMultiplier: Double = 2, graceFloor: TimeInterval = 1.5) {
        self.requestedBytes = requestedBytes
        self.perProbeTimeout = perProbeTimeout
        self.graceMultiplier = graceMultiplier
        self.graceFloor = graceFloor
    }

    public static let standard = MirrorProbeLimits()

    /// How much longer to wait for the others once the first probe has
    /// answered in `elapsed`.
    public func grace(afterFirstAnswerIn elapsed: TimeInterval) -> TimeInterval {
        max(graceFloor, elapsed * graceMultiplier)
    }
}

public enum MirrorProbeRun {
    /// Runs `probe` against every URL at once and returns what finished in
    /// time. A URL with no result timed out or was cut off by the grace period;
    /// `MirrorRanking` treats it as ineligible.
    ///
    /// The grace clock starts at the first probe that actually *answered the
    /// range* rather than the first to finish: a mirror that 404s in 30 ms
    /// says nothing about how long a good answer takes. Cancelling the calling
    /// task cancels every probe, which is how Cancel and Pause stay immediate.
    public static func collect(_ urls: [URL], limits: MirrorProbeLimits = .standard,
                               probe: @escaping @Sendable (URL) async -> MirrorProbeResult)
        async -> [MirrorProbeResult] {
        guard !urls.isEmpty else { return [] }
        let start = ContinuousClock.now
        return await withTaskGroup(of: ProbeEvent.self) { group in
            for url in urls {
                group.addTask { .finished(await probe(url)) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(limits.perProbeTimeout))
                return .deadline
            }
            var results: [MirrorProbeResult] = []
            var graceArmed = false
            loop: while let event = await group.next() {
                if Task.isCancelled { break }
                switch event {
                case .deadline:
                    break loop
                case .finished(let result):
                    results.append(result)
                    if results.count == urls.count { break loop }
                    guard !graceArmed, result.answeredRange else { continue }
                    graceArmed = true
                    let elapsed = start.duration(to: .now) / .seconds(1)
                    let wait = limits.grace(afterFirstAnswerIn: elapsed)
                    group.addTask {
                        try? await Task.sleep(for: .seconds(wait))
                        return .deadline
                    }
                }
            }
            group.cancelAll()
            return results
        }
    }

    private enum ProbeEvent: Sendable {
        case finished(MirrorProbeResult)
        case deadline
    }
}

// MARK: - Ranking (PRD F73)

public enum MirrorRanking {
    /// A mirror has to be this much faster than the original to replace it.
    /// One 1 MiB sample is noisy, and switching servers on a 5% difference
    /// would just make the choice flap between runs.
    public static let displacementFactor = 1.25

    /// The order to try downloading in: mirrors clearly faster than the
    /// original, then the original, then the slower mirrors as further
    /// fallbacks. The original is always present — even when its own probe
    /// failed — because it is what the catalog vouches for; it moves to the
    /// back only when its probe failed and a mirror's did not.
    ///
    /// A mirror is eligible only when it answered with 206, sent at least what
    /// was asked for (or the whole file, if smaller), and reports a total size
    /// equal to the reference: the request's expected size when it has one,
    /// otherwise the original's own reported total. No reference, no mirrors —
    /// with nothing to compare against, a stale or wrong file would look fine.
    public static func rank(primary: URL, results: [MirrorProbeResult],
                            expectedSize: Int64?,
                            requestedBytes: Int64 = MirrorProbeLimits.standard.requestedBytes) -> [URL] {
        let primaryResult = results.first { $0.url == primary }
        let primaryTotal = primaryResult.flatMap { $0.answeredRange ? $0.contentRangeTotal : nil }
        let reference = expectedSize.flatMap { $0 > 0 ? $0 : nil } ?? primaryTotal
        guard let reference else { return [primary] }

        var seen: Set<URL> = [primary]
        let mirrors = results
            .filter { $0.url != primary && seen.insert($0.url).inserted }
            .compactMap { result -> (url: URL, speed: Double)? in
                guard isEligible(result, referenceSize: reference, requestedBytes: requestedBytes),
                      let speed = result.bytesPerSecond else { return nil }
                return (result.url, speed)
            }
            .sorted { $0.speed > $1.speed }

        guard let primaryResult,
              isEligible(primaryResult, referenceSize: reference, requestedBytes: requestedBytes),
              let primarySpeed = primaryResult.bytesPerSecond
        else { return mirrors.map(\.url) + [primary] }

        let faster = mirrors.filter { $0.speed >= primarySpeed * displacementFactor }
        let slower = mirrors.filter { $0.speed < primarySpeed * displacementFactor }
        return faster.map(\.url) + [primary] + slower.map(\.url)
    }

    public static func isEligible(_ result: MirrorProbeResult, referenceSize: Int64,
                                  requestedBytes: Int64) -> Bool {
        guard result.answeredRange, let total = result.contentRangeTotal,
              total == referenceSize else { return false }
        return result.bytesReceived >= min(requestedBytes, total)
    }

    /// The total out of `bytes 0-1048575/5876543488`. Nil for a missing or
    /// unknown (`*`) total, which makes the answer ineligible.
    public static func contentRangeTotal(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let total = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let value = Int64(total), value > 0 else { return nil }
        return value
    }
}
