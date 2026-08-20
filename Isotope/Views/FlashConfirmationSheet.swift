import IsotopeCore
import SwiftUI

/// PRD F29/F30/F31: the dialog that has to be dismissed before a single byte is
/// written. It names the device, its size, and says in as many words that
/// everything on it is erased. macOS's own administrator prompt follows it.
struct FlashConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: FlashPlan
    let onConfirm: (Bool) -> Void

    /// Starts at the Settings default (`AppSettings.flashVerification`); the
    /// toggle here changes this one flash, not the setting.
    @State private var verify: Bool

    init(plan: FlashPlan, verifyByDefault: Bool, onConfirm: @escaping (Bool) -> Void) {
        self.plan = plan
        self.onConfirm = onConfirm
        _verify = State(initialValue: verifyByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Erase and flash “\(plan.device.displayName)”?")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Everything on this device will be erased. Isotope writes the whole device — there is no undo, and any files or volumes on it are gone.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Device", value: plan.device.displayName)
                    LabeledContent("Size", value: ByteCountFormatter.string(
                        fromByteCount: plan.deviceSizeBytes, countStyle: .file))
                    LabeledContent("Device node", value: plan.device.blockDevicePath)
                    if !plan.device.volumeNames.isEmpty {
                        LabeledContent("Currently holds", value: plan.device.volumeNames.joined(separator: ", "))
                    }
                    Divider()
                    LabeledContent("Image", value: "\(plan.title) \(plan.toVersion)")
                    LabeledContent("File", value: plan.fileName)
                    if let size = plan.isoSizeBytes {
                        LabeledContent("Download",
                                       value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let from = plan.fromVersion {
                        LabeledContent("Replaces", value: from)
                    }
                }
                .font(.callout)
                .padding(4)
            }

            // PRD F21: an unverifiable download is labelled at confirmation time.
            if !plan.isVerifiable {
                Label("This source publishes no checksum, so the downloaded image cannot be verified before it is written.",
                      systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = plan.gateFailure {
                Label(failure.reason, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Verify the device after writing", isOn: $verify)
            Text("macOS will ask for an administrator password once the download finishes — that is when the write begins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Flash") {
                    onConfirm(verify)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!plan.canFlash)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
