import AppKit
import IsotopeCore
import SwiftUI

/// PRD F26/F28: registration starts with the *kind* of drive. A Ventoy drive
/// still goes through the open panel (the volume and its bookmark); a flashed
/// drive is picked from the attached USB devices and gets its one image here,
/// because a flashed drive without an assignment has nothing to do.
struct RegisterDriveSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(DriveMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var kind: DriveKind = .ventoy
    @State private var selectedDevice: FlashDevice.ID?
    @State private var selectedEntryID: String?
    @State private var selectedChannelID: String?
    /// PRD F40: what the selected stick's volume label says it already holds.
    @State private var detectedMatch: VolumeLabelMatch?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Register Drive").font(.title2.weight(.semibold))
            Picker("Drive type", selection: $kind) {
                Text("Ventoy drive").tag(DriveKind.ventoy)
                Text("Flashed drive").tag(DriveKind.flashed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(kindExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .flashed { flashedBody }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(kind == .ventoy ? "Choose Volume…" : "Register") { register() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(kind == .flashed && !canRegisterFlashed)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { monitor.refreshDevices() }
        .onChange(of: selectedDevice) { _, deviceID in preselectDetectedImage(deviceID: deviceID) }
    }

    /// PRD F40: picking a stick that already carries a recognisable image
    /// preselects that entry (and channel) rather than making the user find it.
    /// A preselection, never a decision — the pickers stay editable.
    private func preselectDetectedImage(deviceID: FlashDevice.ID?) {
        detectedMatch = nil
        guard let deviceID,
              let device = store.registrableDevices().first(where: { $0.id == deviceID }),
              let match = store.detectedContents(for: device),
              // PRD F32: a match on a non-flashable entry is not offerable.
              let entry = store.flashableEntries.first(where: { $0.id == match.entryID })
        else { return }
        detectedMatch = match
        selectedEntryID = entry.id
        selectedChannelID = match.channelID.flatMap { channelID in
            entry.flashableChannels.first { $0.id == channelID }?.id
        }
    }

    private var kindExplanation: String {
        switch kind {
        case .ventoy:
            return "A Ventoy stick holds ISO files on a normal volume. Isotope copies new ISOs into a folder on it and leaves everything else alone."
        case .flashed:
            return "A flashed stick *is* one image, written to the whole device (balenaEtcher-style). Updating it rewrites the entire device, erasing everything on it — Isotope always asks first."
        }
    }

    // MARK: - Flashed drive

    @ViewBuilder
    private var flashedBody: some View {
        let devices = store.registrableDevices()
        VStack(alignment: .leading, spacing: 8) {
            Text("Device").font(.headline)
            if devices.isEmpty {
                Text("No eligible USB device is attached. Isotope only lists external, removable USB devices that are not the disk macOS runs from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List(devices, selection: $selectedDevice) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                        Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
                        // PRD F40: a dd-flashed stick keeps its ISO's volume
                        // label, so say what it looks like before anything is
                        // written. Read from DiskArbitration — no admin, no
                        // raw reads, and never presented as certain.
                        if let detected = store.detectedContentsSummary(for: device) {
                            Label("Appears to contain: \(detected)", systemImage: "opticaldisc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if device.hardwareID?.isStrongIdentity == false {
                            // PRD F27: no serial → vendor+product+capacity only.
                            Label("This device reports no serial number, so Isotope identifies it by model and capacity.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(device.id)
                }
                .frame(height: 140)
                .border(.separator)
            }

            Text("Image").font(.headline).padding(.top, 4)
            // PRD F32: entries with no direct ISO (Windows) are not offered.
            // PRD F38: grouped by organization, so flavours sit under Ubuntu.
            Picker("Entry", selection: $selectedEntryID) {
                Text("Choose…").tag(String?.none)
                ForEach(store.flashableEntries.groupedByOrganization(), id: \.organization) { group in
                    Section(group.organization) {
                        ForEach(group.entries) { entry in
                            Text(entry.name).tag(String?.some(entry.id))
                        }
                    }
                }
            }
            .labelsHidden()
            if let channels = selectedEntry?.flashableChannels, channels.count > 1 {
                Picker("Channel", selection: $selectedChannelID) {
                    ForEach(channels) { channel in
                        Text(channel.name).tag(String?.some(channel.id))
                    }
                }
            }
            Text("A flashed drive holds exactly one image. You can change which one later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedEntry: CatalogEntry? {
        selectedEntryID.flatMap { store.entry(id: $0) }
    }

    private var resolvedChannelID: String? {
        guard let entry = selectedEntry else { return nil }
        if let selectedChannelID, entry.flashableChannels.contains(where: { $0.id == selectedChannelID }) {
            return selectedChannelID
        }
        return entry.flashableChannels.first?.id
    }

    private var canRegisterFlashed: Bool {
        selectedDevice != nil && resolvedChannelID != nil
    }

    // MARK: - Actions

    private func register() {
        error = nil
        switch kind {
        case .ventoy: registerVentoy()
        case .flashed: registerFlashed()
        }
    }

    /// PRD F1, unchanged: the open panel is still what picks a Ventoy volume
    /// (and, outside the sandbox, still what makes the bookmark meaningful).
    private func registerVentoy() {
        let panel = NSOpenPanel()
        panel.title = "Register Drive"
        panel.message = "Choose the mounted volume Isotope should manage."
        panel.prompt = "Register"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let drive = try store.registerDrive(at: url)
            requestNotificationPermission()
            monitor.rescan(driveID: drive.id)
            store.selection = .drive(drive.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func registerFlashed() {
        guard let deviceID = selectedDevice,
              let device = store.registrableDevices().first(where: { $0.id == deviceID }),
              let entryID = selectedEntryID, let channelID = resolvedChannelID else { return }
        do {
            // PRD F40: the detected version only counts when the user kept the
            // entry it was detected for.
            let detected = detectedMatch?.entryID == entryID ? detectedMatch : nil
            let drive = try store.registerFlashedDrive(device: device, entryID: entryID,
                                                       channelID: channelID, detected: detected)
            requestNotificationPermission()
            monitor.refreshDevices()
            store.selection = .drive(drive.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// In-context permission prompt on first registration (PRD N2).
    private func requestNotificationPermission() {
        let notifications = store.notifications
        Task { await notifications.requestAuthorization() }
    }
}
