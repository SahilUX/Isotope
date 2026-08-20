import IsotopeCore
import SwiftUI

struct DrivesView: View {
    @Environment(AppStore.self) private var store
    @Environment(DriveMonitor.self) private var monitor
    @State private var registrationError: String?
    /// PRD F26: registration starts with the drive kind (Ventoy or flashed).
    @State private var registering = false

    var body: some View {
        @Bindable var store = store
        Group {
            if store.hasAnyDrives {
                List(selection: $store.selection) {
                    ForEach(store.drives) { drive in
                        DriveRow(drive: drive)
                            .tag(SidebarSelection.drive(drive.id))
                    }
                }
            } else {
                firstRunEmptyState
            }
        }
        .navigationTitle("Drives")
        .toolbar {
            Button {
                registering = true
            } label: {
                Label("Register Drive…", systemImage: "plus")
            }
            .help("Register a Ventoy volume or a flashed USB device")
        }
        .sheet(isPresented: $registering) {
            RegisterDriveSheet()
                .environment(store)
                .environment(monitor)
        }
        .alert("Drive not registered", isPresented: showingError) {
            Button("OK", role: .cancel) { registrationError = nil }
        } message: {
            Text(registrationError ?? "")
        }
    }

    private var showingError: Binding<Bool> {
        Binding(get: { registrationError != nil },
                set: { if !$0 { registrationError = nil } })
    }

    /// PRD §7 step 1: fresh launch explains register a drive, assign ISOs.
    ///
    /// Laid out by hand rather than with `ContentUnavailableView`: its `actions`
    /// builder lays multiple actions out in a row, which put the numbered steps
    /// and the button side by side across the full detail pane — the steps then
    /// truncated at the leading edge and the button drifted off to the right.
    /// One centred column with a reading-width cap keeps the whole block
    /// together at any window size.
    private var firstRunEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No drives yet")
                .font(.title2.weight(.semibold))
            Text("Register a plugged-in Ventoy USB drive — or a stick you flash whole with one image — then assign the ISOs you want kept current. Isotope checks for new releases and updates them after you confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                StepLabel(number: 1, text: "Plug in a drive and register it as Ventoy or flashed.")
                StepLabel(number: 2, text: "Assign catalog entries such as Ubuntu LTS or SystemRescue.")
                StepLabel(number: 3, text: "Confirm updates when a newer ISO is released.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            Button("Register Drive…") { registering = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        // Wide enough that step 2 — the longest line — never wraps awkwardly or
        // truncates, narrow enough to stay a readable column on a wide window.
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StepLabel: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            // Wrap rather than truncate if the window is ever narrower than the
            // step text needs.
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// Green up to date · orange N updates · red needs attention · grey disconnected
/// (DESIGN §5, PRD F2/F42).
///
/// PRD F42: grey is *only* "not connected". A connected drive whose assignments
/// could not all be compared yet is still green — drawn hollow, the "checking /
/// not fully known" affinity indicator F42 allows — never grey.
struct DriveStatusDot: View {
    let status: DriveStatus

    var body: some View {
        Circle()
            .fill(isPartlyKnown ? AnyShapeStyle(color.opacity(0.25)) : AnyShapeStyle(color))
            .frame(width: 8, height: 8)
            .overlay {
                if isPartlyKnown { Circle().strokeBorder(color, lineWidth: 1.5) }
            }
            .accessibilityLabel(status.summary)
    }

    private var isPartlyKnown: Bool { status == .unknown }

    private var color: Color {
        switch status {
        case .disconnected: return .secondary
        case .needsAttention: return .red
        case .upToDate, .unknown: return .green
        case .updates: return .orange
        }
    }
}

private struct DriveRow: View {
    @Environment(AppStore.self) private var store
    let drive: ManagedDrive

    var body: some View {
        let status = store.status(of: drive)
        HStack(spacing: 10) {
            Image(systemName: store.isConnected(drive) ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(store.isConnected(drive) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.displayName)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            DriveStatusDot(status: status)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let count = drive.assignments.count
        let assignments = "\(count) assignment\(count == 1 ? "" : "s")"
        if store.isConnected(drive) { return "\(assignments) · Connected" }
        guard let seen = drive.lastSeenAt else { return "\(assignments) · Never seen" }
        return "\(assignments) · Last seen \(seen.formatted(date: .abbreviated, time: .shortened))"
    }
}
