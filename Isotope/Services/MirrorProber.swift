import Foundation
import IsotopeCore

/// PRD F73: measures how quickly each candidate URL serves the start of a file.
/// A protocol so `DownloadManager` can be tested offline with canned timings;
/// what the numbers *mean* is decided in IsotopeCore (`MirrorRanking`).
protocol MirrorProbing: Sendable {
    /// One result per URL that answered in time; a missing URL timed out or
    /// was cut off. Must return promptly when the calling task is cancelled.
    func probe(_ urls: [URL]) async -> [MirrorProbeResult]
}

/// Asks every candidate for its first MiB at once (`Range: bytes=0-1048575`)
/// and times it, connection setup included.
///
/// Its own ephemeral session: no cookies, no cache, nothing written to disk,
/// and a hard timeout per request. A data task rather than `bytes(for:)`, so a
/// server that ignores the range and starts sending the whole ISO is cut off
/// at the first callback instead of being read byte by byte.
final class URLSessionMirrorProber: MirrorProbing, @unchecked Sendable {
    private let session: URLSession
    private let limits: MirrorProbeLimits

    init(limits: MirrorProbeLimits = .standard,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.limits = limits
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = limits.perProbeTimeout
        configuration.timeoutIntervalForResource = limits.perProbeTimeout
        self.session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func probe(_ urls: [URL]) async -> [MirrorProbeResult] {
        let limits = self.limits
        return await MirrorProbeRun.collect(urls, limits: limits) { [session] url in
            await Self.probeOne(url, session: session, bytes: limits.requestedBytes)
        }
    }

    private static func probeOne(_ url: URL, session: URLSession, bytes: Int64) async -> MirrorProbeResult {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        // A compressed body would make the byte count meaningless.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let reader = RangeReader(url: url, wanted: bytes)
        let task = session.dataTask(with: request)
        task.delegate = reader
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reader.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Per-task delegate: reads until it has `wanted` bytes (or the body ends),
/// then cancels the task and reports.
private final class RangeReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let wanted: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MirrorProbeResult, Never>?
    private var started = ContinuousClock.now
    private var status: Int?
    private var total: Int64?
    private var received: Int64 = 0

    init(url: URL, wanted: Int64) {
        self.url = url
        self.wanted = wanted
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<MirrorProbeResult, Never>) {
        lock.lock()
        self.continuation = continuation
        started = ContinuousClock.now
        lock.unlock()
        // Cancelled before it began: `onCancel` has already run, so a resumed
        // task would sit out its whole timeout.
        if Task.isCancelled { task.cancel() }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        lock.lock()
        status = http?.statusCode
        total = MirrorRanking.contentRangeTotal(http?.value(forHTTPHeaderField: "Content-Range"))
        lock.unlock()
        // Anything but a partial answer is ineligible, and a 200 here is the
        // start of the whole ISO: stop now.
        guard http?.statusCode == 206 else {
            finish()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received += Int64(data.count)
        let done = received >= wanted
        lock.unlock()
        guard done else { return }
        finish()
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A body shorter than the range (a small file) ends here normally;
        // a cancellation or failure reports whatever arrived, which the
        // ranking judges.
        finish()
    }

    private func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = MirrorProbeResult(url: url, statusCode: status, contentRangeTotal: total,
                                       bytesReceived: received,
                                       elapsed: started.duration(to: .now) / .seconds(1))
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
