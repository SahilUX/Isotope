import Foundation
import IsotopeCore

/// UserDefaults-backed knobs the pipeline reads (PRD F19/F20). Phase 5 surfaces
/// the rest of Settings; these three already have real behaviour behind them, so
/// they are stored rather than hard-coded.
///
/// A `UserDefaults` instance is injected so tests get their own suite and never
/// mutate the developer's real preferences.
/// `UserDefaults` is documented as thread-safe but is not marked `Sendable`.
struct AppSettings: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let cacheCapacityBytes = "cacheCapacityBytes"
        static let refreshInterval = "refreshIntervalSeconds"
        static let notificationsEnabled = "notificationsEnabled"
        static let autoResumeDownloads = "autoResumeDownloads"
        static let flashVerification = "flashVerification"
        static let discardAfterPlacement = "discardCachedISOAfterPlacement"
    }

    /// PRD F47: delete a downloaded ISO from the cache the moment it has been
    /// copied to a drive (or flashed onto one). **On by default.**
    ///
    /// The cache's only job is to save a second download; once the file is on
    /// the stick, keeping a multi-gigabyte copy in `~/Library/Caches` is
    /// hoarding, and the LRU cap only notices at 20 GB. Off keeps the old
    /// behaviour, which is worth it if the same ISO goes onto several drives on
    /// different days.
    var discardAfterPlacement: Bool {
        get { defaults.object(forKey: Key.discardAfterPlacement) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.discardAfterPlacement) }
    }

    /// PRD F29: after writing an image, read the device back and compare
    /// SHA-256. On by default — it roughly doubles the time a flash takes, but
    /// a stick that silently wrote garbage is worse than a slow one.
    var flashVerification: Bool {
        get { defaults.object(forKey: Key.flashVerification) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.flashVerification) }
    }

    /// PRD F16: the drive-connect and completion notices can be switched off
    /// without revoking the system permission.
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// PRD F19: on launch, either resume interrupted downloads straight away or
    /// (the default) just offer them in Activity.
    var autoResumeDownloads: Bool {
        get { defaults.object(forKey: Key.autoResumeDownloads) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.autoResumeDownloads) }
    }

    /// PRD F19: default 2, configurable. Clamped so a bad value cannot wedge the
    /// queue at zero or hammer a mirror with fifty sockets.
    var maxConcurrentDownloads: Int {
        get {
            let stored = defaults.object(forKey: Key.maxConcurrentDownloads) as? Int
            return min(8, max(1, stored ?? 2))
        }
        nonmutating set { defaults.set(min(8, max(1, newValue)), forKey: Key.maxConcurrentDownloads) }
    }

    /// PRD F20: default 20 GB. `0` disables the cap.
    var cacheCapacityBytes: Int64 {
        get {
            let stored = defaults.object(forKey: Key.cacheCapacityBytes) as? NSNumber
            return max(0, stored?.int64Value ?? CacheIndex.defaultCapacityBytes)
        }
        nonmutating set { defaults.set(NSNumber(value: max(0, newValue)), forKey: Key.cacheCapacityBytes) }
    }

    /// PRD F12: default 6 h.
    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.object(forKey: Key.refreshInterval) as? Double
            return max(15 * 60, stored ?? 6 * 60 * 60)
        }
        nonmutating set { defaults.set(max(15 * 60, newValue), forKey: Key.refreshInterval) }
    }
}
