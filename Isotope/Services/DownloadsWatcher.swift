import Foundation
import IsotopeCore

/// One ISO found sitting in the user's Downloads folder.
struct FoundISO: Identifiable, Hashable, Sendable {
    var url: URL
    var fileName: String
    var sizeBytes: Int64
    var modifiedAt: Date

    var id: URL { url }
}

/// PRD §5.4: Microsoft's ISO links are session-generated, so Isotope sends the
/// user to the browser and then watches `~/Downloads` for the file to land.
///
/// Polling rather than an FSEvents stream: the watch is only live while the
/// Windows sheet is open, and a five-second poll over one directory is cheaper
/// than the machinery of a stream (and works identically under the sandbox's
/// `files.downloads.read-only` entitlement).
@Observable
@MainActor
final class DownloadsWatcher {
    private(set) var candidates: [FoundISO] = []
    private(set) var isWatching = false
    private var task: Task<Void, Never>?

    /// Regex matched against the filename; `Win11.*\.iso` for the Windows entry.
    var pattern: String = #"(?i)^win.*\.iso$"#
    var interval: TimeInterval = 5
    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

    func start() {
        guard task == nil else { return }
        isWatching = true
        scan()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    /// Newest first — the file the user just fetched is the one they mean.
    func scan() {
        candidates = Self.matches(in: folder, pattern: pattern)
    }

    static func matches(in folder: URL, pattern: String) -> [FoundISO] {
        let matcher = try? PatternMatcher(pattern, caseInsensitive: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return contents.compactMap { url -> FoundISO? in
            let name = url.lastPathComponent
            guard DownloadArtifact.isISO(name) else { return nil }
            guard matcher == nil || matcher?.matchesAnywhere(name) == true else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { return nil }
            return FoundISO(url: url, fileName: name,
                            sizeBytes: Int64(values?.fileSize ?? 0),
                            modifiedAt: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
