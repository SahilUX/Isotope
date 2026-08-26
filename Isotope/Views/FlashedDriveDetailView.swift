import IsotopeCore
import SwiftUI

/// DESIGN §9 UI: device info, the single assignment, installed → latest, and the
/// Flash button that goes through the confirmation dialog (PRD F29/F30). No ISO
/// folder, no keep-old-versions, no bookmark: none of them mean anything when
/// the device *is* the image.
struct FlashedDriveDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(DriveMonitor.self) private var monitor
    let driveID: UUID

    @State private var pendingPlan: FlashPlan?
    @State private var confirmingUnregister = false
    @State private var actionError: String?

    var body: some View {
        Group {
            if let drive = store.drive(id: driveID) {
                content(for: drive).navigationTitle(drive.displayName)
            } else {
                ContentUnavailableView("Drive not found", systemImage: "externaldrive.badge.questionmark")
            }
        }
        .alert("Action failed", isPresented: showingError) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        // PRD F29/F30/F31: nothing is written until this dialog is confirmed,
        // and macOS's own administrator prompt follows it.
        .sheet(item: $pendingPlan) { plan in
            FlashConfirmationSheet(plan: plan,
                                   verifyByDefault: store.settings.flashVerification) { verify in
                store.startFlash(plan, verify: verify)
            }
        }
    }

    private var showingError: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    @ViewBuilder
    private func content(for drive: ManagedDrive) -> some View {
        List {
            if let failure = drive.flashFailure {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure.message).font(.callout)
                    }
                }
            }
            // PRD F40: the stick's volume label stopped looking like the image
            // it is registered as holding — someone re-flashed it elsewhere.
            if let issue = store.driveIssues[drive.id] {
                Section { DriveIssueBanner(issue: issue) }
            }
            if store.flashEjectOffers.contains(drive.id) {
                Section {
                    HStack {
                        Label("Flash complete — it is safe to remove this device.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Eject") { store.ejectFlashedDrive(driveID: drive.id) }
                        Button("Dismiss") { store.clearFlashEjectOffer(driveID: drive.id) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
            Section { header(for: drive) }
            imageSection(for: drive)
            deviceSection(for: drive)
            settingsSection(for: drive)
        }
        .toolbar {
            Button {
                monitor.refreshDevices()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Re-read the attached USB devices")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for drive: ManagedDrive) -> some View {
        let device = store.attachedDevice(for: drive)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DriveStatusDot(status: store.status(of: drive))
                Text(drive.displayName).font(.title2.weight(.semibold))
                Text("Flashed drive")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button("Eject", systemImage: "eject") { store.ejectFlashedDrive(driveID: drive.id) }
                    .disabled(device == nil || store.hasOperationsInFlight(drive))
            }
            Text(connectionSummary(drive: drive, device: device))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func connectionSummary(drive: ManagedDrive, device: FlashDevice?) -> String {
        guard let device else {
            guard let seen = drive.lastSeenAt else { return "Not connected" }
            return "Not connected · Last seen \(seen.formatted(date: .abbreviated, time: .shortened))"
        }
        let size = ByteCountFormatter.string(fromByteCount: device.sizeBytes, countStyle: .file)
        return "Connected at \(device.bsdName) · \(size) · \(store.status(of: drive).summary)"
    }

    // MARK: - The one image (PRD F26)

    @ViewBuilder
    private func imageSection(for drive: ManagedDrive) -> some View {
        Section("Image") {
            if let assignment = drive.singleAssignment {
                let staleness = store.staleness(of: assignment, on: drive)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.title(for: assignment))
                    Text(versionSummary(assignment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    statusLabel(staleness)
                    Spacer()
                    if let operation = activeOperation(assignment) {
                        FlashOperationBadge(operation: operation)
                    } else {
                        Button(flashButtonTitle(assignment: assignment, staleness: staleness)) {
                            requestFlash()
                        }
                        .disabled(!canFlash(drive: drive, assignment: assignment))
                        .help(flashHelp(drive: drive, assignment: assignment))
                    }
                }
                // PRD F37: the policy applies here too — a pinned image is never
                // reported stale and never triggers a reflash notification. The
                // single-assignment invariant is untouched.
                Toggle("Keep this image as is (never prompt to reflash)", isOn: Binding(
                    get: { assignment.isPinned },
                    set: { store.setUpdatePolicy($0 ? .keepAsIs : .trackLatest,
                                                 forAssignment: assignment.id, on: drive.id) }))
                ChangeImageMenu(drive: drive)
            } else {
                Text("No image assigned yet.").foregroundStyle(.secondary)
                ChangeImageMenu(drive: drive)
            }
        }
    }

    private func activeOperation(_ assignment: Assignment) -> UpdateOperationState? {
        store.operations.first { $0.assignmentID == assignment.id && $0.isActive }
    }

    private func versionSummary(_ assignment: Assignment) -> String {
        let installed = assignment.installed?.displayVersion ?? "Never flashed"
        guard !assignment.isPinned else { return "\(installed) · kept as is" }
        let latest = store.release(for: assignment)?.displayVersion ?? "unknown"
        return "\(installed) → \(latest)"
    }

    private func flashButtonTitle(assignment: Assignment, staleness: Staleness) -> String {
        assignment.installed == nil ? "Flash Now…" : "Flash Update…"
    }

    private func canFlash(drive: ManagedDrive, assignment: Assignment) -> Bool {
        store.isConnected(drive) && store.release(for: assignment) != nil
            && !store.hasOperationsInFlight(drive)
    }

    private func flashHelp(drive: ManagedDrive, assignment: Assignment) -> String {
        if !store.isConnected(drive) { return "Attach the device to flash it" }
        if store.release(for: assignment) == nil { return "No release resolved yet — check the catalog" }
        return "Erase the device and write this image to it"
    }

    @ViewBuilder
    private func statusLabel(_ staleness: Staleness) -> some View {
        switch staleness {
        case .pinned:
            Label("Pinned", systemImage: "pin.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .buildBehind:
            Text("Newer build shipped").font(.caption).foregroundStyle(.secondary)
                .help("This is the current release, but Microsoft has shipped a newer build of it.")
        case .stale:
            Text("Update available").font(.caption).foregroundStyle(.orange)
        case .notInstalled:
            Text("Never flashed").font(.caption).foregroundStyle(.secondary)
        case .unknown:
            Text("Unknown").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func requestFlash() {
        guard let plan = store.flashPlan(driveID: driveID) else {
            actionError = "Isotope could not prepare this flash. Make sure the device is attached and a release has been resolved for its image."
            return
        }
        pendingPlan = plan
    }

    // MARK: - Device (PRD F27)

    @ViewBuilder
    private func deviceSection(for drive: ManagedDrive) -> some View {
        Section("Device") {
            if let hardware = drive.hardwareID {
                LabeledContent("USB identity") {
                    Text(hardware.displayText).font(.callout.monospaced()).textSelection(.enabled)
                }
                if !hardware.isStrongIdentity {
                    Text("This device reports no serial number, so Isotope recognises it by model and capacity. Two identical sticks would look the same.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let device = store.attachedDevice(for: drive) {
                LabeledContent("Device node", value: device.blockDevicePath)
                LabeledContent("Capacity",
                               value: ByteCountFormatter.string(fromByteCount: device.sizeBytes,
                                                                countStyle: .file))
                if !device.volumeNames.isEmpty {
                    LabeledContent("Volumes", value: device.volumeNames.joined(separator: ", "))
                }
            } else if let capacity = drive.capacityBytes {
                LabeledContent("Capacity",
                               value: ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
            }
            if !drive.volumeUUID.isEmpty {
                LabeledContent("Volume UUID") {
                    Text(drive.volumeUUID).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsSection(for drive: ManagedDrive) -> some View {
        Section("Drive Settings") {
            Toggle("Verify the device after flashing", isOn: Binding(
                get: { store.settings.flashVerification },
                set: { store.settings.flashVerification = $0 }))
            Text("Reads the whole device back and compares SHA-256 with the ISO. Roughly doubles the time a flash takes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Unregister Drive…", role: .destructive) { confirmingUnregister = true }
                .disabled(store.hasOperationsInFlight(drive))
                .confirmationDialog("Stop managing “\(drive.displayName)”?",
                                    isPresented: $confirmingUnregister, titleVisibility: .visible) {
                    Button("Unregister", role: .destructive) { store.unregisterDrive(id: drive.id) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Isotope forgets this device. Nothing on it is erased or changed.")
                }
        }
    }
}

/// PRD F26: one image per flashed drive, so this replaces rather than adds.
private struct ChangeImageMenu: View {
    @Environment(AppStore.self) private var store
    let drive: ManagedDrive

    var body: some View {
        Menu {
            // PRD F32: `windowsManual` entries never appear here.
            // PRD F38: grouped by organization, as everywhere else.
            ForEach(store.flashableEntries.groupedByOrganization(), id: \.organization) { group in
                Section(group.organization) {
                    ForEach(group.entries) { entry in
                        if entry.flashableChannels.count == 1,
                           let channel = entry.flashableChannels.first {
                            Button(entry.name) { select(entry.id, channel.id) }
                        } else {
                            Menu(entry.name) {
                                ForEach(entry.flashableChannels) { channel in
                                    Button(channel.name) { select(entry.id, channel.id) }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(drive.singleAssignment == nil ? "Choose Image" : "Change Image", systemImage: "arrow.triangle.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.hasOperationsInFlight(drive))
    }

    private func select(_ entryID: String, _ channelID: String) {
        store.setFlashedAssignment(entryID: entryID, channelID: channelID, on: drive.id)
    }
}

private struct FlashOperationBadge: View {
    let operation: UpdateOperationState

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = operation.fractionCompleted {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            // PRD F63: a flash is the longest thing Isotope does — writing
            // and then reading back a whole device — so it says how fast and
            // how long, exactly as a copy does.
            VStack(alignment: .trailing, spacing: 1) {
                Text(operation.phase.label)
                if let detail = TransferSummary.rateAndRemaining(bytesPerSecond: operation.bytesPerSecond,
                                                                 eta: operation.eta) {
                    Text(detail).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(TransferSummary.bytes(completed: operation.completedBytes, total: operation.totalBytes))
        }
    }
}
