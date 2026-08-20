import Foundation
import os
import UserNotifications

/// DESIGN §4.6. Behind a protocol because `UNUserNotificationCenter.current()`
/// traps in a headless test bundle (no app bundle identifier) — tests inject
/// `RecordingNotificationService`, the app injects the real one.
protocol NotificationPosting: Sendable {
    func requestAuthorization() async
    /// PRD F16: one notification per drive-connect, summarising its updates.
    func postDriveUpdates(driveID: UUID, driveName: String, summaries: [String]) async
    /// Completion notice for a finished or failed update (only when the app is
    /// not frontmost — the caller decides).
    func postOperationFinished(title: String, driveName: String,
                               succeeded: Bool, message: String?) async
}

/// What a click on a notification means: focus the app on that drive.
@MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()
    var onOpenDrive: ((UUID) -> Void)?
}

struct UserNotificationService: NotificationPosting {
    static let driveIDKey = "driveID"
    static let driveCategory = "isotope.drive-updates"

    /// `UNUserNotificationCenter.current()` requires a bundle; a test host or a
    /// command-line run has none, and asking would crash rather than fail.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && NSClassFromString("UNUserNotificationCenter") != nil
    }

    func requestAuthorization() async {
        guard Self.isAvailable else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func postDriveUpdates(driveID: UUID, driveName: String, summaries: [String]) async {
        guard Self.isAvailable, !summaries.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if summaries.count == 1 {
            // "Ubuntu 24.04.4 available for 'SanDisk 64GB'" (PRD F16).
            content.title = "\(summaries[0]) available for “\(driveName)”"
        } else {
            content.title = "\(summaries.count) updates available for “\(driveName)”"
            content.body = summaries.joined(separator: ", ")
        }
        content.userInfo = [Self.driveIDKey: driveID.uuidString]
        content.categoryIdentifier = Self.driveCategory
        await post(content, identifier: "drive-\(driveID.uuidString)")
    }

    func postOperationFinished(title: String, driveName: String,
                               succeeded: Bool, message: String?) async {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = succeeded ? "\(title) updated on “\(driveName)”" : "\(title) failed on “\(driveName)”"
        if let message { content.body = message }
        await post(content, identifier: "op-\(UUID().uuidString)")
    }

    private func post(_ content: UNMutableNotificationContent, identifier: String) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Routes notification clicks back into the app (DESIGN §4.6 deep link).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[UserNotificationService.driveIDKey] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { NotificationRouter.shared.onOpenDrive?(id) }
    }

    /// Show the banner even when Isotope is frontmost; the drive-connect notice
    /// is the whole point of PRD F16.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Test double, and the fallback whenever notifications are unavailable.
///
/// State lives behind one `OSAllocatedUnfairLock`, whose `withLock` never spans
/// an `await` — the manual `lock()`/`unlock()` pair this replaced is an error
/// when called from an async context under the Swift 6 language mode.
final class RecordingNotificationService: NotificationPosting, Sendable {
    struct DriveNotice: Equatable, Sendable {
        var driveID: UUID
        var driveName: String
        var summaries: [String]
    }

    private struct State {
        var driveNotices: [DriveNotice] = []
        var completions: [String] = []
        var authorizationRequests = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var driveNotices: [DriveNotice] { state.withLock { $0.driveNotices } }
    var completions: [String] { state.withLock { $0.completions } }
    var authorizationRequests: Int { state.withLock { $0.authorizationRequests } }

    func requestAuthorization() async {
        state.withLock { $0.authorizationRequests += 1 }
    }

    func postDriveUpdates(driveID: UUID, driveName: String, summaries: [String]) async {
        let notice = DriveNotice(driveID: driveID, driveName: driveName, summaries: summaries)
        state.withLock { $0.driveNotices.append(notice) }
    }

    func postOperationFinished(title: String, driveName: String,
                               succeeded: Bool, message: String?) async {
        let entry = "\(succeeded ? "ok" : "fail"):\(title)@\(driveName)"
        state.withLock { $0.completions.append(entry) }
    }
}
