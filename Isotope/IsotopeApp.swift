import SwiftUI
import UserNotifications

@main
struct IsotopeApp: App {
    @State private var store: AppStore
    @State private var monitor: DriveMonitor
    /// Held for the app's lifetime: `UNUserNotificationCenter` keeps its
    /// delegate weakly.
    private let notificationDelegate = NotificationDelegate()
    /// PRD F19: a clean quit has to park in-flight downloads first, which needs
    /// `applicationShouldTerminate` — SwiftUI has no equivalent hook.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        _monitor = State(initialValue: DriveMonitor(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(monitor)
                .task {
                    appDelegate.store = store
                    await store.loadAtLaunch()
                    store.startPipeline()
                    installNotificationRouting()
                    // Volumes first: a drive that is already plugged in should be
                    // connected and scanned before the catalog sweep lands (F3/F7).
                    monitor.start()
                    store.startPeriodicRefresh()
                    await store.refreshCatalog()   // launch trigger (PRD F12)
                }
        }
        // The minimum size is declared per column (sidebar in `RootView`, detail
        // in `RootView.detail`) and the window is held to their sum. A single
        // `.frame(minWidth:)` on the split view itself is what broke this
        // before: AppKit handed the *detail* column that whole minimum, the
        // split view grew wider than the window, and the sidebar was pushed off
        // the leading edge — a blank sidebar and a left-clipped detail pane.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check for Updates") {
                    Task { await store.refreshCatalog() }
                }
                .keyboardShortcut("r")
            }
        }
    }

    /// PRD F16: clicking a drive notification focuses the app on that drive.
    private func installNotificationRouting() {
        guard UserNotificationService.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NotificationRouter.shared.onOpenDrive = { [store] driveID in
            guard store.drive(id: driveID) != nil else { return }
            store.selection = .drive(driveID)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}


/// Clean-quit handling (PRD F19, DESIGN §6 "app quit mid-download"): downloads
/// are paused and their resume data persisted before the process exits, so the
/// relaunch can offer to carry on where it left off.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    /// Give the parking a couple of seconds; a wedged `URLSession` must never
    /// stop the user quitting.
    static let quitTimeout: TimeInterval = 3

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.downloadManager != nil else { return .terminateNow }
        Task {
            await store.prepareForQuit()
            reply(to: sender)
        }
        // A wedged URLSession must never stop the user quitting.
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.quitTimeout * 1_000_000_000))
            reply(to: sender)
        }
        return .terminateLater
    }

    private var hasReplied = false

    private func reply(to sender: NSApplication) {
        guard !hasReplied else { return }
        hasReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
