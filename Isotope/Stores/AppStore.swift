import Foundation
import IsotopeCore
import Observation

/// Single observable source of truth for the UI (DESIGN §2). Phase 1 holds state
/// and persistence only; CatalogService / DriveMonitor / UpdateEngine plug in later.
@Observable
@MainActor
final class AppStore {
    // Persisted state
    private(set) var drives: [ManagedDrive] = []
    private(set) var builtInEntries: [CatalogEntry] = []
    private(set) var customEntries: [CatalogEntry] = []
    /// Resolved releases keyed by `ReleaseKey.description` ("<entryID>#<channelID>").
    private(set) var releases: [String: Release] = [:]
    private(set) var history: [HistoryEvent] = []

    // Transient state. `operations` is written by the update pipeline in
    // AppStore+Updates.swift (Swift's `private(set)` cannot span files).
    var operations: [UpdateOperationState] = []
    /// PRD F19: downloads interrupted by a quit or a failure, offered on relaunch.
    var interruptedDownloads: [InterruptedDownload] = []
    /// Last set of update summaries announced per drive, so replugging a stick
    /// does not re-post the same notification (PRD F16).
    var lastAnnouncedUpdates: [UUID: [String]] = [:]
    private(set) var isCheckingCatalog = false
    private(set) var lastLoadError: String?
    /// Per-channel check status keyed by `ReleaseKey.description` (PRD F14).
    private(set) var checkStatus: [String: CheckStatus] = [:]
    private(set) var lastCheckStartedAt: Date?

    // Transient drive state. Written by DriveMonitor and the drive-scan code in
    // AppStore+Drives.swift (Swift's `private(set)` cannot span files); the views
    // only ever read it.
    /// Mounted volumes Isotope knows about, keyed by volume UUID.
    var connectedVolumes: [String: VolumeInfo] = [:]
    /// PRD F4: a registered drive whose volume no longer matches its registration.
    var driveIssues: [UUID: DriveIssue] = [:]
    /// PRD F7: `.iso` files on the drive that no assignment claims — informational only.
    var unknownISOFiles: [UUID: [String]] = [:]
    var lastScanAt: [UUID: Date] = [:]
    var isScanning: Set<UUID> = []
    /// (assignment, filename) pairs whose Windows media has already been
    /// inspected for its build (PRD F43 addendum), successfully or not. Mounting
    /// an ISO is slow, so a file is asked exactly once; a new file on the same
    /// assignment is a new key and is asked afresh.
    var windowsBuildAttempts: Set<String> = []

    /// Drives with a download/copy in flight. Phase 4's UpdateEngine owns this
    /// set; Phase 3 only reads it, to keep Eject and Unregister safe (PRD F23).
    var drivesWithOperationsInFlight: Set<UUID> = []

    // Flashed drives (PRD §8). Written by `DriveMonitor`'s device watcher and
    // the flash pipeline in AppStore+Flash.swift.
    /// External USB whole disks currently attached — the identity source for
    /// flashed drives, which have no mounted volume to key on (PRD F27).
    var attachedDevices: [FlashDevice] = []
    /// Drives whose flash just finished, so the detail view can offer the eject
    /// (PRD F23). Cleared when the offer is taken or dismissed.
    var flashEjectOffers: Set<UUID> = []

    /// Volume metadata + bookmark creation, injectable so tests can register
    /// drives without a real USB stick.
    var driveProbe: DriveProbe = .live

    /// PRD F49: the opt-in "ask Microsoft for a link" attempt. Injectable so
    /// tests can exercise both answers without touching the network.
    var windowsResolver: WindowsDownloadResolving = WindowsDownloadResolver()

    var selection: SidebarSelection? = .drives

    /// PRD F12: default 6 h while the app runs; configurable in Settings.
    var refreshInterval: TimeInterval = 6 * 60 * 60

    let hashing: Hashing = CryptoKitHashing()
    let catalogService: CatalogService
    let settings: AppSettings
    /// PRD F16 / DESIGN §4.6. Defaults to the real notification centre in the
    /// app and to a recorder wherever `UNUserNotificationCenter` is unusable
    /// (test bundles have no bundle identifier and would trap).
    var notifications: NotificationPosting = UserNotificationService.isAvailable
        ? UserNotificationService() : RecordingNotificationService()
    /// Wired at launch by `IsotopeApp`; nil in tests that never update anything.
    var updateEngine: UpdateEngine?
    /// PRD §8; nil until `startPipeline` runs, and injected directly by tests.
    var flashEngine: FlashEngine?
    var downloadManager: DownloadManager?
    var isoCache: ISOCache?
    private let locations: StoreLocations
    private let catalogResourceURL: URL?
    private var periodicRefresh: Task<Void, Never>?

    /// `catalogResourceURL` defaults to the bundled `catalog.json`; tests inject
    /// a temporary root, a fixture catalog and a stubbed `CatalogService`
    /// instead of touching the user's real state or the network.
    init(locations: StoreLocations = .applicationSupport(),
         catalogResourceURL: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json"),
         catalogService: CatalogService = CatalogService(),
         settings: AppSettings = AppSettings()) {
        self.locations = locations
        self.catalogResourceURL = catalogResourceURL
        self.catalogService = catalogService
        self.settings = settings
        self.refreshInterval = settings.refreshInterval
    }

    /// Builds the download/update pipeline (DESIGN §4.4/§4.5). Separate from
    /// `init` so tests can either skip it or inject their own fakes.
    func startPipeline(cacheLocations: CacheLocations = .userCaches()) {
        guard updateEngine == nil else { return }
        let cache = ISOCache(locations: cacheLocations, capacityBytes: settings.cacheCapacityBytes)
        let downloads = DownloadManager(cache: cache, locations: cacheLocations, hashing: hashing,
                                        maxConcurrent: settings.maxConcurrentDownloads)
        isoCache = cache
        downloadManager = downloads
        updateEngine = UpdateEngine(store: self, downloads: downloads)
        // PRD §8: the same cache and download manager feed the flash pipeline,
        // so a Ventoy copy and a flash of the same ISO share one download (F20).
        flashEngine = FlashEngine(store: self, downloads: downloads,
                                  io: LiveFlashDeviceIO(enumerator: DeviceEnumerator()),
                                  hashing: hashing)
        Task { [weak self] in
            let resumable = await downloads.resumableDownloads()
            await MainActor.run {
                guard let self else { return }
                self.interruptedDownloads = resumable
                // PRD F19: resume automatically, or leave them offered in
                // Activity, per the Settings toggle.
                guard self.settings.autoResumeDownloads else { return }
                for download in resumable where self.canResumeInterruptedDownload(download) {
                    self.resumeInterruptedDownload(download)
                }
            }
        }
    }

    /// Clean quit (PRD F19): park in-flight downloads with resume data so a
    /// relaunch can carry on. Called from `applicationShouldTerminate`.
    func prepareForQuit() async {
        stopPeriodicRefresh()
        guard let downloads = downloadManager else { return }
        await downloads.suspendForQuit()
    }

    func stopPeriodicRefresh() {
        periodicRefresh?.cancel()
        periodicRefresh = nil
    }

    // MARK: - Derived state

    /// Built-in entries first, then user-created ones (DESIGN §5 CatalogView sections).
    var allEntries: [CatalogEntry] { builtInEntries + customEntries }

    func entry(id: String) -> CatalogEntry? { allEntries.first { $0.id == id } }

    func release(for assignment: Assignment) -> Release? {
        releases[assignment.releaseKey.description]
    }

    /// Assignments whose installed version is missing or older than the resolved
    /// release. The comparison itself lives in IsotopeCore (`Staleness`).
    ///
    /// PRD F36: pinned (`keepAsIs`) assignments evaluate to `.pinned`, so they
    /// drop out here — and with them out of "Update All", the drive status dot
    /// and the drive-connect notification, which all read this one function.
    func staleAssignments(on drive: ManagedDrive) -> [Assignment] {
        drive.assignments.filter { staleness(of: $0, on: drive).needsUpdate }
    }

    func staleness(of assignment: Assignment) -> Staleness {
        Staleness.evaluate(assignment: assignment, latest: release(for: assignment))
    }

    /// Drive-aware staleness: a flashed stick whose last flash failed is in an
    /// undefined state, so it is never displayed as up to date (DESIGN §9).
    func staleness(of assignment: Assignment, on drive: ManagedDrive) -> Staleness {
        drive.displayedStaleness(staleness(of: assignment))
    }

    var hasAnyDrives: Bool { !drives.isEmpty }

    /// PRD F47: whether a placed ISO is deleted from the cache immediately.
    /// Read by `UpdateEngine`/`FlashEngine`, which are actors and cannot touch
    /// `settings` directly.
    var discardsCacheAfterPlacement: Bool { settings.discardAfterPlacement }

    func status(for key: ReleaseKey) -> CheckStatus { checkStatus[key.description] ?? .never }

    func release(for key: ReleaseKey) -> Release? { releases[key.description] }

    /// Drives that reference `entryID`, so deleting a custom source can warn
    /// before it orphans assignments (PRD F11).
    func drivesUsing(entryID: String) -> [ManagedDrive] {
        drives.filter { drive in drive.assignments.contains { $0.entryID == entryID } }
    }

    // MARK: - Loading

    func loadAtLaunch() async {
        do {
            try locations.ensureDirectoryExists()
            builtInEntries = loadBundledCatalog()
            customEntries = try JSONStore.load([CatalogEntry].self, from: locations.customSources) ?? []
            drives = try JSONStore.load([ManagedDrive].self, from: locations.drives) ?? []
            releases = try JSONStore.load([String: Release].self, from: locations.releaseCache) ?? [:]
            history = try JSONStore.load([HistoryEvent].self, from: locations.history) ?? []
            lastLoadError = nil
        } catch {
            // Corrupt state must be visible, not silently discarded (PRD F25 spirit).
            lastLoadError = error.localizedDescription
        }
    }

    private func loadBundledCatalog() -> [CatalogEntry] {
        guard let catalogResourceURL else { return [] }
        do {
            let data = try Data(contentsOf: catalogResourceURL)
            return try JSONStore.loadJSON([CatalogEntry].self, from: data)
        } catch {
            lastLoadError = "Bundled catalog could not be read: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Mutation + persistence

    func addDrive(_ drive: ManagedDrive) {
        drives.append(drive)
        persistDrives()
    }

    func removeDrive(id: UUID) {
        drives.removeAll { $0.id == id }
        persistDrives()
    }

    func updateDrive(_ drive: ManagedDrive) {
        guard let index = drives.firstIndex(where: { $0.id == drive.id }) else { return }
        drives[index] = drive
        persistDrives()
    }

    func addCustomEntry(_ entry: CatalogEntry) {
        customEntries.removeAll { $0.id == entry.id }
        customEntries.append(entry)
        persist(customEntries, to: locations.customSources)
    }

    func removeCustomEntry(id: String) {
        customEntries.removeAll { $0.id == id }
        persist(customEntries, to: locations.customSources)
    }

    func setRelease(_ release: Release, for key: ReleaseKey) {
        releases[key.description] = release
        persist(releases, to: locations.releaseCache)
    }

    /// Newest first (DESIGN §5 ActivityView), bounded so `history.json` cannot
    /// grow without limit on a long-lived install.
    func appendHistory(_ event: HistoryEvent) {
        history.insert(event, at: 0)
        if history.count > AppStore.historyLimit { history.removeLast(history.count - AppStore.historyLimit) }
        persist(history, to: locations.history)
    }

    static let historyLimit = 500

    /// Settings' "Clear history" (PRD F24). Only the log is discarded; nothing
    /// on any drive is touched.
    func clearHistory() {
        history = []
        persist(history, to: locations.history)
    }

    /// PRD F12/F14 — checks every entry. Failures are recorded per channel and
    /// never abort the sweep; results land as they arrive.
    func refreshCatalog() async {
        guard !isCheckingCatalog else { return }
        let entries = allEntries
        guard !entries.isEmpty else { return }
        isCheckingCatalog = true
        lastCheckStartedAt = Date()
        for entry in entries {
            for channel in entry.channels {
                checkStatus[ReleaseKey(entryID: entry.id, channelID: channel.id).description] = .checking
            }
        }
        await catalogService.check(entries: entries) { [weak self] key, outcome in
            await self?.apply(outcome, for: key)
        }
        isCheckingCatalog = false
    }

    /// Targeted check of a subset of channels — the drive-mount trigger only
    /// refreshes the entries that drive actually uses (DESIGN §4.2/§4.3).
    func checkChannels(_ jobs: [(key: ReleaseKey, config: ProviderConfig)]) async {
        guard !jobs.isEmpty else { return }
        for job in jobs { checkStatus[job.key.description] = .checking }
        await withTaskGroup(of: (ReleaseKey, CatalogService.Outcome).self) { group in
            for job in jobs {
                group.addTask { [catalogService] in
                    (job.key, await catalogService.checkOne(config: job.config))
                }
            }
            for await (key, outcome) in group { apply(outcome, for: key) }
        }
    }

    private func apply(_ outcome: CatalogService.Outcome, for key: ReleaseKey) {
        switch outcome {
        case .success(let release):
            // Change-detection sources have no version of their own; keep the
            // previously recorded change date when the signature is unchanged.
            let resolved = release.carryingOverChangeDate(from: releases[key.description])
            setRelease(resolved, for: key)
            checkStatus[key.description] = .ok(resolved.checkedAt)
        case .failure(let message):
            checkStatus[key.description] = .failed(message, Date())
        }
    }

    /// Launch + 6 h timer triggers (DESIGN §4.2). Manual refresh calls
    /// `refreshCatalog()` directly; a manual run in flight is skipped by its own guard.
    func startPeriodicRefresh() {
        periodicRefresh?.cancel()
        periodicRefresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refreshCatalog()
            }
        }
    }

    /// Runs one provider live without persisting anything — the Test button in
    /// CustomSourceSheet (PRD F10).
    func testProvider(_ config: ProviderConfig) async -> CatalogService.Outcome {
        await catalogService.checkOne(config: config)
    }

    private func persistDrives() { persist(drives, to: locations.drives) }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        do {
            try JSONStore.save(value, to: url)
        } catch {
            lastLoadError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

extension StoreLocations {
    /// `~/Library/Application Support/Isotope/` (PRD N6).
    static func applicationSupport() -> StoreLocations {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return StoreLocations(root: base.appendingPathComponent("Isotope", isDirectory: true))
    }
}

/// PRD F14: OK (version + checked time) / failed (readable error) / checking.
enum CheckStatus: Equatable {
    case never
    case checking
    case ok(Date)
    case failed(String, Date)

    var isChecking: Bool { self == .checking }

    var errorMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }

    var checkedAt: Date? {
        switch self {
        case .ok(let date), .failed(_, let date): return date
        case .never, .checking: return nil
        }
    }
}

enum SidebarSelection: Hashable {
    case drives
    case drive(UUID)
    case catalog
    case activity
    case settings
}
