import IsotopeCore
import SwiftUI

/// PRD F17: updates always require explicit confirmation, and the dialog spells
/// out exactly what will happen — including the F21 **unverified** warning when
/// a source publishes no checksum.
struct UpdateConfirmationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: UpdatePlan
    /// Called with the automatable half of the plan once the user confirms.
    var onConfirm: (UpdatePlan) -> Void

    /// PRD F35: items whose replaced ISO the user chose to keep as a pinned
    /// copy. Off by default — the F6 default is still "replace".
    @State private var pinnedItemIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.items) { item in
                        PlanRow(item: item, keepAsPinnedCopy: keepBinding(for: item))
                    }
                    if plan.hasUnverified { unverifiedWarning }
                    if !plan.manualItems.isEmpty { manualNotice }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var title: String {
        plan.items.count == 1
            ? "Update \(plan.items[0].title)?"
            : "Update \(plan.items.count) ISOs on “\(plan.driveName)”?"
    }

    private var subtitle: String {
        var parts = ["Isotope downloads each ISO, verifies it where a checksum exists, and copies it to the drive."]
        if let total = plan.totalBytes {
            parts.append("About \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) to download.")
        }
        return parts.joined(separator: " ")
    }

    private var unverifiedWarning: some View {
        Label {
            Text("One or more of these sources publishes no SHA-256 checksum, so Isotope cannot verify the download. It will be copied as-is.")
        } icon: {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }

    private var manualNotice: some View {
        Label {
            Text("\(plan.manualItems.map(\.title).joined(separator: ", ")) must be downloaded from the vendor by hand, so \(plan.manualItems.count == 1 ? "it is" : "they are") skipped here — \(automatableSummary) will be updated now. Use “Get ISO…” on the row afterwards.")
        } icon: {
            Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var confirmButtonTitle: String {
        let count = plan.automatableItems.count
        guard !plan.manualItems.isEmpty, count > 0 else {
            return count > 1 ? "Update All" : "Update"
        }
        // Mixed batch: name the number that will actually run.
        return count > 1 ? "Update \(count)" : "Update 1"
    }

    private var automatableSummary: String {
        let count = plan.automatableItems.count
        if count == 0 { return "nothing else" }
        return count == 1 ? "the other ISO" : "the other \(count) ISOs"
    }

    /// PRD F35: the checkbox is per item, so the confirmed plan carries the
    /// choice item by item rather than as one drive-wide flag.
    private var confirmedPlan: UpdatePlan {
        var confirmed = plan
        for index in confirmed.items.indices where pinnedItemIDs.contains(confirmed.items[index].id) {
            confirmed.items[index].keepReplacedAsPinned = true
        }
        return confirmed
    }

    private func keepBinding(for item: UpdatePlanItem) -> Binding<Bool> {
        Binding(get: { pinnedItemIDs.contains(item.id) },
                set: { keep in
                    if keep { pinnedItemIDs.insert(item.id) } else { pinnedItemIDs.remove(item.id) }
                })
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmButtonTitle) {
                onConfirm(confirmedPlan)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plan.automatableItems.isEmpty)
        }
        .padding(16)
    }
}

private struct PlanRow: View {
    let item: UpdatePlanItem
    @Binding var keepAsPinnedCopy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.title).fontWeight(.medium)
                Text(versionArrow).foregroundStyle(.secondary)
                Spacer()
                if item.needsManualDownload {
                    // PRD §5.4: spelled out on the row itself, so a mixed
                    // "Update All" cannot look like it covers this one.
                    Text("Skipped — manual download")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if !item.isVerifiable {
                    // PRD F21: label it, clearly, at confirmation time.
                    Text("Unverified")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            // PRD F35: the one place several versions of an OS start living
            // side by side on purpose.
            if item.canKeepReplacedAsPinned {
                Toggle("Keep current version on the drive as a pinned copy",
                       isOn: $keepAsPinnedCopy)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .padding(.top, 1)
                if keepAsPinnedCopy, let old = item.installedFileName {
                    Text("“\(old)” stays on the drive and is tracked as a pinned assignment — Isotope never updates or deletes it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(item.needsManualDownload ? 0.65 : 1)
    }

    private var versionArrow: String {
        guard let from = item.fromVersion else { return "→ \(item.toVersion)" }
        return "\(from) → \(item.toVersion)"
    }

    private var detail: String {
        if item.needsManualDownload {
            return "Isotope cannot fetch this one automatically — use “Get ISO…” on its row afterwards."
        }
        var parts: [String] = [item.fileName]
        if let size = item.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if keepAsPinnedCopy {
            parts.append("old version pinned")
        } else if let replaced = item.replacesFileName, replaced != item.fileName {
            parts.append("replaces \(replaced)")
        } else if item.replacesFileName == nil, item.fromVersion != nil {
            parts.append("old version kept")
        }
        return parts.joined(separator: " · ")
    }
}
