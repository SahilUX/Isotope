import Foundation
import IsotopeCore
import Observation

/// The UserDefaults-backed knobs behind Settings. Every one of them has real
/// behaviour in the pipeline, which is why they are stored rather than
/// hard-coded.
///
/// A `UserDefaults` instance is injected so tests get their own suite and never
/// mutate the developer's real preferences.
///
/// **Observable, and deliberately a class.** As a struct behind `UserDefaults`
/// this was invisible to SwiftUI: a `Toggle` bound to it wrote the new value and
/// then carried on drawing the old one, because nothing ever invalidated the
/// view. Every switch in Settings looked broken while working perfectly.
///
/// The macro only instruments *stored* properties, and every property here is
/// computed over `UserDefaults`, so each one calls `access`/`withMutation` by
/// hand — that is what makes reading one in a view body register a dependency.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

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
        static let windowsAutoDownload = "attemptWindowsAutoDownload"
    }

    /// PRD F49: try to fetch a Windows ISO without the browser before falling
    /// back to the hand-off sheet. **Off by default, and deliberately so.**
    ///
    /// Microsoft's link-minting endpoint answers "Sentinel marked this request
    /// as rejected" to anything that does not look like a browser session — it
    /// refused a correctly sequenced request from an ordinary connection during
    /// development. On, Isotope tries anyway and says plainly when it is
    /// refused; the manual flow is right there either way.
    var attemptWindowsAutoDownload: Bool {
        get {
            access(keyPath: \.attemptWindowsAutoDownload)
            return defaults.object(forKey: Key.windowsAutoDownload) as? Bool ?? false
        }
        set { withMutation(keyPath: \.attemptWindowsAutoDownload) { defaults.set(newValue, forKey: Key.windowsAutoDownload) } }
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
        get {
            access(keyPath: \.discardAfterPlacement)
            return defaults.object(forKey: Key.discardAfterPlacement) as? Bool ?? true
        }
        set { withMutation(keyPath: \.discardAfterPlacement) { defaults.set(newValue, forKey: Key.discardAfterPlacement) } }
    }

    /// PRD F29: after writing an image, read the device back and compare
    /// SHA-256. On by default — it roughly doubles the time a flash takes, but
    /// a stick that silently wrote garbage is worse than a slow one.
    var flashVerification: Bool {
        get {
            access(keyPath: \.flashVerification)
            return defaults.object(forKey: Key.flashVerification) as? Bool ?? true
        }
        set { withMutation(keyPath: \.flashVerification) { defaults.set(newValue, forKey: Key.flashVerification) } }
    }

    /// PRD F16: the drive-connect and completion notices can be switched off
    /// without revoking the system permission.
    var notificationsEnabled: Bool {
        get {
            access(keyPath: \.notificationsEnabled)
            return defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        }
        set { withMutation(keyPath: \.notificationsEnabled) { defaults.set(newValue, forKey: Key.notificationsEnabled) } }
    }

    /// PRD F19: on launch, either resume interrupted downloads straight away or
    /// (the default) just offer them in Activity.
    var autoResumeDownloads: Bool {
        get {
            access(keyPath: \.autoResumeDownloads)
            return defaults.object(forKey: Key.autoResumeDownloads) as? Bool ?? false
        }
        set { withMutation(keyPath: \.autoResumeDownloads) { defaults.set(newValue, forKey: Key.autoResumeDownloads) } }
    }

    /// PRD F19: default 2, configurable. Clamped so a bad value cannot wedge the
    /// queue at zero or hammer a mirror with fifty sockets.
    var maxConcurrentDownloads: Int {
        get {
            access(keyPath: \.maxConcurrentDownloads)
            let stored = defaults.object(forKey: Key.maxConcurrentDownloads) as? Int
            return min(8, max(1, stored ?? 2))
        }
        set { withMutation(keyPath: \.maxConcurrentDownloads) { defaults.set(min(8, max(1, newValue)), forKey: Key.maxConcurrentDownloads) } }
    }

    /// PRD F20: default 20 GB. `0` disables the cap.
    var cacheCapacityBytes: Int64 {
        get {
            access(keyPath: \.cacheCapacityBytes)
            let stored = defaults.object(forKey: Key.cacheCapacityBytes) as? NSNumber
            return max(0, stored?.int64Value ?? CacheIndex.defaultCapacityBytes)
        }
        set { withMutation(keyPath: \.cacheCapacityBytes) { defaults.set(NSNumber(value: max(0, newValue)), forKey: Key.cacheCapacityBytes) } }
    }

    /// PRD F12: default 6 h.
    var refreshInterval: TimeInterval {
        get {
            access(keyPath: \.refreshInterval)
            let stored = defaults.object(forKey: Key.refreshInterval) as? Double
            return max(15 * 60, stored ?? 6 * 60 * 60)
        }
        set { withMutation(keyPath: \.refreshInterval) { defaults.set(max(15 * 60, newValue), forKey: Key.refreshInterval) } }
    }
}
