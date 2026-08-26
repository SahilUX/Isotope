import IsotopeCore
import SwiftUI

/// PRD F12/F16/F19/F20/F24: check interval, notifications, download
/// concurrency and resume policy, the ISO cache, and the history log.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var cacheBytes: Int64?
    @State private var clearing = false
    @State private var confirmingHistoryClear = false
    /// PRD F49: the result of Settings' "Test" button, so the toggle is not the
    /// only feedback a feature this likely to be refused ever gives.
    @State private var windowsTest: WindowsDownloadAttempt?
    @State private var isTestingWindows = false

    var body: some View {
        Form {
            Section("Checks") {
                Picker("Interval", selection: intervalBinding) {
                    Text("Every hour").tag(TimeInterval(3600))
                    Text("Every 6 hours").tag(TimeInterval(6 * 3600))
                    Text("Every 12 hours").tag(TimeInterval(12 * 3600))
                    Text("Once a day").tag(TimeInterval(24 * 3600))
                }
                LabeledContent("Per-source timeout", value: "15 seconds")
            }
            Section("Notifications") {
                Toggle("Notify me when a connected drive has updates", isOn: notificationsBinding)
                Text("Isotope posts one banner per drive, and a notice when an update finishes while the app is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Concurrent downloads", selection: concurrencyBinding) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Interrupted downloads", selection: autoResumeBinding) {
                    Text("Offer to resume in Activity").tag(false)
                    Text("Resume automatically on launch").tag(true)
                }
                Picker("Cache limit", selection: cacheCapacityBinding) {
                    Text("5 GB").tag(Int64(5) << 30)
                    Text("10 GB").tag(Int64(10) << 30)
                    Text("20 GB").tag(Int64(20) << 30)
                    Text("50 GB").tag(Int64(50) << 30)
                    Text("No limit").tag(Int64(0))
                }
                LabeledContent("Cached ISOs") {
                    HStack {
                        Text(cacheBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                             ?? "—")
                        Button("Refresh") { Task { await refreshCacheSize() } }
                            .buttonStyle(.link)
                        Button(clearing ? "Clearing…" : "Clear") { clearCache() }
                            .disabled(clearing || (cacheBytes ?? 0) == 0)
                    }
                }
                // PRD F47: on by default — the cache is a download-saver, not a
                // second copy of every ISO the user already has on a stick.
                Toggle("Delete a downloaded ISO once it is on the drive", isOn: discardAfterPlacementBinding)
                Text("On (the default), a download is deleted the moment it has been copied or flashed, so ISOs do not pile up in ~/Library/Caches — an image another drive is still waiting for is kept until that drive has it too. Off, ISOs stay cached up to the limit above, so updating a second drive on another day needs no download. Files a copy is using right now are never deleted either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Windows") {
                // PRD F49: off by default, and the copy says why rather than
                // implying it usually works.
                Toggle("Try to download Windows ISOs without the browser", isOn: windowsAutoDownloadBinding)
                Text("Microsoft's download service refuses requests that do not come from a browser, so this usually fails and Isotope falls back to opening the download page. When it does work, the ISO is checksum-verified like any other. Nothing is downloaded without your say-so either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The toggle alone tells you nothing about whether Microsoft
                // will play along. This asks them, now, and shows the answer.
                LabeledContent("Check whether it works") {
                    Button(isTestingWindows ? "Asking Microsoft…" : "Test Now") { testWindowsDownload() }
                        .disabled(isTestingWindows || store.firstWindowsChannel == nil)
                }
                if let windowsTest { windowsTestResult(windowsTest) }
            }
            Section("Flashing") {
                // PRD F29: read-back verification, on by default.
                Toggle("Verify the device after flashing", isOn: flashVerificationBinding)
                Text("After writing an image to a flashed drive, Isotope reads the whole device back and compares SHA-256 with the ISO. It roughly doubles the time a flash takes. Flashing always asks for confirmation and for your administrator password, whatever this is set to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                LabeledContent("Recorded updates") {
                    HStack {
                        Text("\(store.history.count)")
                        Button("Clear…") { confirmingHistoryClear = true }
                            .disabled(store.history.isEmpty)
                    }
                }
                .confirmationDialog("Clear the update history?",
                                    isPresented: $confirmingHistoryClear, titleVisibility: .visible) {
                    Button("Clear History", role: .destructive) { store.clearHistory() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Only the log is discarded. Nothing on any drive changes.")
                }
            }
            if let error = store.lastLoadError {
                Section("Last error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await refreshCacheSize() }
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(get: { store.refreshInterval }, set: { value in
            store.settings.refreshInterval = value
            store.refreshInterval = value
            store.startPeriodicRefresh()
        })
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(get: { store.settings.notificationsEnabled }, set: { value in
            store.settings.notificationsEnabled = value
            // Turning them on in Settings is as good a moment as any to ask for
            // the system permission, if it was never granted (PRD N2).
            guard value else { return }
            let service = store.notifications
            Task { await service.requestAuthorization() }
        })
    }

    private var flashVerificationBinding: Binding<Bool> {
        Binding(get: { store.settings.flashVerification },
                set: { store.settings.flashVerification = $0 })
    }

    private var autoResumeBinding: Binding<Bool> {
        Binding(get: { store.settings.autoResumeDownloads },
                set: { store.settings.autoResumeDownloads = $0 })
    }

    private var concurrencyBinding: Binding<Int> {
        Binding(get: { store.settings.maxConcurrentDownloads }, set: { value in
            store.settings.maxConcurrentDownloads = value
            if let downloads = store.downloadManager {
                Task { await downloads.setMaxConcurrent(value) }
            }
        })
    }

    /// Runs the real attempt against the first Windows channel in the catalog —
    /// the same code path an update takes, so a pass here means a pass there.
    private func testWindowsDownload() {
        guard let channel = store.firstWindowsChannel else { return }
        isTestingWindows = true
        windowsTest = nil
        Task {
            windowsTest = await store.attemptWindowsDownload(entryID: channel.entryID,
                                                             channelID: channel.channelID)
            isTestingWindows = false
        }
    }

    @ViewBuilder
    private func windowsTestResult(_ attempt: WindowsDownloadAttempt) -> some View {
        switch attempt {
        case .resolved(let download):
            VStack(alignment: .leading, spacing: 2) {
                Label("Microsoft answered with a link", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Text(download.fileName).font(.caption.monospaced()).textSelection(.enabled)
                Text(download.sha256 == nil
                     ? "No checksum came with it, so a download would be labelled unverified."
                     : "A checksum came with it, so downloads will be verified as usual.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .refused(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("Microsoft refused", systemImage: "hand.raised.fill")
                    .font(.callout).foregroundStyle(.orange)
                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                Text("Expected — their service rejects non-browser clients. Windows downloads will open the download page instead, which works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("The attempt could not be made", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var windowsAutoDownloadBinding: Binding<Bool> {
        Binding(get: { store.settings.attemptWindowsAutoDownload },
                set: { store.settings.attemptWindowsAutoDownload = $0 })
    }

    private var discardAfterPlacementBinding: Binding<Bool> {
        Binding(get: { store.settings.discardAfterPlacement },
                set: { store.settings.discardAfterPlacement = $0 })
    }

    private var cacheCapacityBinding: Binding<Int64> {
        Binding(get: { store.settings.cacheCapacityBytes }, set: { value in
            store.settings.cacheCapacityBytes = value
            guard let cache = store.isoCache else { return }
            Task {
                await cache.setCapacity(value)
                await refreshCacheSize()
            }
        })
    }

    private func refreshCacheSize() async {
        guard let cache = store.isoCache else { return }
        cacheBytes = await cache.totalBytes
    }

    private func clearCache() {
        guard let cache = store.isoCache else { return }
        clearing = true
        Task {
            _ = await cache.clear()
            await refreshCacheSize()
            clearing = false
        }
    }
}
