import IsotopeCore
import SwiftUI

/// DESIGN §5: in-flight operations with progress / speed / ETA / pause / cancel,
/// then the persistent history log (PRD F24).
struct ActivityView: View {
    @Environment(AppStore.self) private var store

    private var isEmpty: Bool {
        store.operations.isEmpty && store.history.isEmpty && store.interruptedDownloads.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                // DESIGN §5 empty state: nothing has happened yet, and the view
                // says what would make something happen.
                ContentUnavailableView {
                    Label("Nothing yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("Downloads, copies and finished updates show up here. Assign an ISO to a drive and confirm an update to get started.")
                }
            } else {
                list
            }
        }
        .navigationTitle("Activity")
    }

    private var list: some View {
        List {
            if !store.interruptedDownloads.isEmpty {
                Section("Interrupted downloads") {
                    ForEach(store.interruptedDownloads) { download in
                        InterruptedDownloadRow(download: download)
                    }
                }
            }
            Section {
                if store.operations.isEmpty {
                    Text("Nothing downloading or copying.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.operations) { operation in
                        OperationRow(operation: operation)
                    }
                }
            } header: {
                HStack {
                    Text("In progress")
                    Spacer()
                    if store.operations.contains(where: { !$0.isActive }) {
                        Button("Clear finished") { store.clearFinishedOperations() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Section("History") {
                if store.history.isEmpty {
                    Text("No updates yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.history) { event in
                        HistoryRow(event: event)
                    }
                }
            }
        }
    }
}

// MARK: - In-flight operation

private struct OperationRow: View {
    @Environment(AppStore.self) private var store
    let operation: UpdateOperationState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(operation.title).fontWeight(.medium)
                Text(operation.version).foregroundStyle(.secondary)
                Spacer()
                Text(operation.driveName).font(.caption).foregroundStyle(.secondary)
            }
            if operation.isActive {
                progressBar
                HStack {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    controls
                }
            } else {
                Label(terminalSummary, systemImage: terminalIcon)
                    .font(.caption)
                    .foregroundStyle(terminalColor)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = operation.fractionCompleted {
            ProgressView(value: fraction).progressViewStyle(.linear)
        } else {
            // No Content-Length (or hashing/unpacking): indeterminate.
            ProgressView().progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if operation.canPause {
                Button(operation.isPaused ? "Resume" : "Pause") {
                    if operation.isPaused {
                        store.resumeOperation(id: operation.id)
                    } else {
                        store.pauseOperation(id: operation.id)
                    }
                }
                .buttonStyle(.link)
            }
            Button("Cancel") { store.cancelOperation(id: operation.id) }
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    private var statusLine: String {
        if operation.isPaused { return "Paused · \(byteSummary)" }
        var parts = [operation.phase.label]
        if !byteSummary.isEmpty { parts.append(byteSummary) }
        if let detail = TransferSummary.rateAndRemaining(bytesPerSecond: operation.bytesPerSecond,
                                                         eta: operation.eta) {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private var byteSummary: String {
        TransferSummary.bytes(completed: operation.completedBytes, total: operation.totalBytes)
    }

    private var terminalSummary: String {
        switch operation.phase {
        case .completed: return "Copied \(operation.fileName) to “\(operation.driveName)”"
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        default: return operation.phase.label
        }
    }

    private var terminalIcon: String {
        switch operation.phase {
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "slash.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var terminalColor: Color {
        switch operation.phase {
        case .completed: return .green
        case .cancelled: return .secondary
        default: return .orange
        }
    }

}

// MARK: - Resume offer (PRD F19)

private struct InterruptedDownloadRow: View {
    @Environment(AppStore.self) private var store
    let download: InterruptedDownload

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { store.resumeInterruptedDownload(download) }
                .disabled(!store.canResumeInterruptedDownload(download))
            Button("Discard") { store.discardInterruptedDownload(download) }
                .buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let done = ByteCountFormatter.string(fromByteCount: download.bytesDownloaded, countStyle: .file)
        let reason = download.wasPaused ? "Paused" : "Interrupted"
        let target = download.driveName.map { " · for “\($0)”" } ?? ""
        return "\(reason) at \(done)\(target) · \(download.interruptedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - History

private struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message ?? "\(event.fileName) → \(event.driveName)")
                Text("\(event.driveName) · \(event.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private var icon: String {
        switch event.outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var color: Color {
        switch event.outcome {
        case .succeeded: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        }
    }
}
