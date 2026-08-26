import AppKit
import IsotopeCore
import SwiftUI

/// DESIGN §5: header (name, capacity, connected state, Eject) · assignment rows ·
/// Add Assignment · unknown files · drive settings · unregister.
struct DriveDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(DriveMonitor.self) private var monitor
    let driveID: UUID

    @State private var isoFolderDraft: String = ""
    @State private var confirmingUnregister = false
    @State private var actionError: String?
    /// PRD F17: nothing is downloaded until this plan is confirmed.
    @State private var pendingPlan: UpdatePlan?
    /// PRD §5.4: the Windows hand-off sheet.
    @State private var manualItem: UpdatePlanItem?

    var body: some View {
        Group {
            if store.drive(id: driveID)?.isFlashed == true {
                // PRD §8: a flashed drive has no ISO folder, no bookmark and one
                // image, so it gets its own detail view rather than a pile of
                // disabled controls.
                FlashedDriveDetailView(driveID: driveID)
            } else if let drive = store.drive(id: driveID) {
                content(for: drive)
                    .navigationTitle(drive.displayName)
                    .onAppear { isoFolderDraft = drive.isoFolder }
                    .onChange(of: driveID) { isoFolderDraft = store.drive(id: driveID)?.isoFolder ?? "" }
            } else {
                ContentUnavailableView("Drive not found", systemImage: "externaldrive.badge.questionmark")
            }
        }
        .alert("Action failed", isPresented: showingError) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(item: $pendingPlan) { plan in
            UpdateConfirmationSheet(plan: plan) { confirmed in
                store.startUpdates(confirmed)
            }
            .environment(store)
        }
        .sheet(item: $manualItem) { item in
            WindowsManualSheet(item: item,
                               downloadPage: store.manualDownloadPage(entryID: item.entryID,
                                                                      channelID: item.channelID))
                .environment(store)
        }
    }

    /// PRD F17: one row's Update button. A manual entry has nothing to confirm
    /// — it goes straight to the hand-off sheet (PRD §5.4).
    private func requestUpdate(assignmentID: UUID) {
        let plan = store.updatePlan(driveID: driveID, assignmentIDs: [assignmentID])
        guard !plan.isEmpty else { return }
        if plan.items.count == 1, let manual = plan.manualItems.first {
            manualItem = manual
        } else {
            pendingPlan = plan
        }
    }

    private func requestUpdateAll() {
        let plan = store.updatePlanForAllStale(driveID: driveID)
        guard !plan.isEmpty else { return }
        pendingPlan = plan
    }

    private var showingError: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    @ViewBuilder
    private func content(for drive: ManagedDrive) -> some View {
        List {
            if let issue = store.driveIssues[drive.id] {
                Section { DriveIssueBanner(issue: issue) }
            }
            // DESIGN §6: a read-only mount is surfaced before the user starts an
            // update, not only when the pre-flight rejects it.
            if store.volumeInfo(for: drive)?.isReadOnly == true {
                Section {
                    Label("“\(drive.displayName)” is mounted read-only, so Isotope cannot write to it. Check the drive's write-protect switch, or remount it.",
                          systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section { DriveHeader(drive: drive, onEject: eject) }
            assignmentsSection(for: drive)
            detectedFilesSection(for: drive)
            unknownFilesSection(for: drive)
            settingsSection(for: drive)
        }
        .toolbar {
            Button {
                monitor.rescan(driveID: drive.id)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!store.isConnected(drive))
            .help(store.isConnected(drive) ? "Re-read the drive's ISO folder" : "Connect the drive to rescan")
        }
    }

    // MARK: - Assignments

    @ViewBuilder
    private func assignmentsSection(for drive: ManagedDrive) -> some View {
        Section {
            if drive.assignments.isEmpty {
                Text("No ISOs assigned yet. Use Add Assignment to track one.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(drive.assignments) { assignment in
                    AssignmentRow(assignment: assignment, driveID: drive.id,
                                  onUpdate: { requestUpdate(assignmentID: assignment.id) })
                }
            }
        } header: {
            HStack {
                Text("Assignments")
                Spacer()
                // PRD F17 batch confirmation.
                if store.staleAssignments(on: drive).count > 1 {
                    Button("Update All") { requestUpdateAll() }
                        .disabled(!store.isConnected(drive))
                }
                AddAssignmentMenu(drive: drive)
            }
        }
    }

    // MARK: - Found on drive (PRD F41)

    @ViewBuilder
    private func detectedFilesSection(for drive: ManagedDrive) -> some View {
        let detected = store.detectedISOs(on: drive)
        if !detected.isEmpty {
            Section {
                ForEach(detected) { item in
                    DetectedISORow(detected: item, driveID: drive.id)
                }
            } header: {
                Text("Found on this drive")
            } footer: {
                Text("Isotope recognised these ISOs but does not track them yet. Track the latest release, or keep the file exactly as it is — either way nothing on the drive is changed.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func unknownFilesSection(for drive: ManagedDrive) -> some View {
        let unknown = store.unrecognizedISOFiles(on: drive)
        if !unknown.isEmpty {
            Section {
                ForEach(unknown, id: \.self) { name in
                    Label(name, systemImage: "doc.questionmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Unrecognised files")
            } footer: {
                Text("Isotope found these files but does not recognise them. They are never modified or deleted.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private func settingsSection(for drive: ManagedDrive) -> some View {
        Section("Drive Settings") {
            LabeledContent("Volume UUID") {
                Text(drive.volumeUUID).font(.callout.monospaced()).textSelection(.enabled)
            }
            LabeledContent("ISO folder") {
                HStack(spacing: 6) {
                    TextField("Volume root", text: $isoFolderDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { store.setISOFolder(normalizedFolder, for: drive.id) }
                    // PRD F6: pick the folder rather than type a path — the
                    // panel is rooted at the drive so it cannot wander off it.
                    Button("Choose…") { chooseISOFolder(for: drive) }
                        .disabled(!store.isConnected(drive))
                        .help(store.isConnected(drive)
                              ? "Browse the drive for the folder Isotope should write to"
                              : "Connect the drive to browse it")
                    if !isoFolderDraft.isEmpty {
                        Button("Use Root") {
                            isoFolderDraft = ""
                            store.setISOFolder("", for: drive.id)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            Toggle("Keep old versions after an update", isOn: Binding(
                get: { drive.keepOldVersions },
                set: { store.setKeepOldVersions($0, for: drive.id) }))
            if let scanned = store.lastScanAt[drive.id] {
                LabeledContent("Last scan",
                               value: scanned.formatted(date: .abbreviated, time: .shortened))
            }
            Button("Unregister Drive…", role: .destructive) { confirmingUnregister = true }
                .disabled(store.hasOperationsInFlight(drive))
                .confirmationDialog("Stop managing “\(drive.displayName)”?",
                                    isPresented: $confirmingUnregister, titleVisibility: .visible) {
                    Button("Unregister", role: .destructive) { store.unregisterDrive(id: drive.id) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Isotope forgets this drive and its assignments. Nothing on the drive is deleted or changed.")
                }
        }
    }

    /// PRD F6 / F22: a standard open panel rooted at the drive, so the stored
    /// folder is always a path *inside* the volume Isotope manages.
    private func chooseISOFolder(for drive: ManagedDrive) {
        guard let volume = store.volumeInfo(for: drive)?.url else {
            actionError = "Connect “\(drive.displayName)” to choose a folder on it."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "ISO Folder"
        panel.message = "Choose the folder on “\(drive.displayName)” where Isotope keeps ISOs."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = volume
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard let relative = Self.relativePath(of: chosen, inside: volume) else {
            actionError = "That folder is not on “\(drive.displayName)”. Choose a folder on the drive itself."
            return
        }
        isoFolderDraft = relative
        store.setISOFolder(relative, for: drive.id)
    }

    /// "" for the volume root, "ISOs/linux" for a subfolder, nil when the
    /// chosen folder is not on the volume at all.
    static func relativePath(of folder: URL, inside volume: URL) -> String? {
        let root = volume.standardizedFileURL.resolvingSymlinksInPath().path
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if target == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// Trim the hand-typed folder so "/ISOs/" and "ISOs" behave the same.
    private var normalizedFolder: String {
        isoFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func eject() {
        do {
            try store.eject(driveID: driveID)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Header

private struct DriveHeader: View {
    @Environment(AppStore.self) private var store
    let drive: ManagedDrive
    let onEject: () -> Void

    var body: some View {
        let info = store.volumeInfo(for: drive)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DriveStatusDot(status: store.status(of: drive))
                Text(drive.displayName).font(.title2.weight(.semibold))
                Spacer()
                Button("Eject", systemImage: "eject") { onEject() }
                    .disabled(info == nil || store.hasOperationsInFlight(drive))
            }
            Text(connectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            capacityBar(info: info)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func capacityBar(info: VolumeInfo?) -> some View {
        if let capacity = info?.capacityBytes ?? drive.capacityBytes, capacity > 0 {
            let free = info?.availableBytes
            let used = free.map { max(0, capacity - $0) }
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(used ?? 0), total: Double(capacity))
                    .progressViewStyle(.linear)
                Text(capacitySummary(capacity: capacity, free: free))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capacitySummary(capacity: Int64, free: Int64?) -> String {
        let total = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        guard let free else { return "\(total) capacity" }
        return "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free of \(total)"
    }

    private var connectionSummary: String {
        if store.isConnected(drive) {
            let readOnly = store.volumeInfo(for: drive)?.isReadOnly == true ? " · Read-only" : ""
            return "Connected\(readOnly) · \(store.status(of: drive).summary)"
        }
        guard let seen = drive.lastSeenAt else { return "Not connected" }
        return "Not connected · Last seen \(seen.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Warning banner (PRD F4, and PRD F40's "contents changed")

struct DriveIssueBanner: View {
    let issue: DriveIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(issue.message).font(.callout)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Assignment row

private struct AssignmentRow: View {
    @Environment(AppStore.self) private var store
    let assignment: Assignment
    let driveID: UUID
    let onUpdate: () -> Void

    var body: some View {
        let entry = store.entry(id: assignment.entryID)
        let channel = entry?.channel(id: assignment.channelID)
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry?.kind))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(entry: entry, channel: channel))
                Text(versionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let operation = activeOperation {
                OperationBadge(operation: operation)
            } else {
                statusLabel
                // PRD F33: the pin is one click away on the row itself; the
                // context menu spells both policies out.
                Button {
                    setPolicy(assignment.isPinned ? .trackLatest : .keepAsIs)
                } label: {
                    // The icon is the *action*, not the state: a pinned row
                    // offers "unpin", an unpinned one offers "pin". The state
                    // itself is already on the row, in `statusLabel`.
                    Image(systemName: assignment.isPinned ? "pin.slash" : "pin.fill")
                }
                .buttonStyle(.borderless)
                .disabled(assignment.isPinned && !canTrackLatest)
                .help(pinHelp)
                if !assignment.isPinned, store.staleness(of: assignment).needsUpdate {
                    Button(isManual ? "Get ISO…" : "Update") { onUpdate() }
                        .disabled(!isUpdatable)
                        .help(updateHelp)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Track Latest") { setPolicy(.trackLatest) }
                .disabled(!canTrackLatest)
            Button("Keep as Is (Pin)") { setPolicy(.keepAsIs) }
                .disabled(assignment.isPinned)
            Divider()
            Button("Remove Assignment", role: .destructive) {
                store.removeAssignment(id: assignment.id, from: driveID)
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                store.removeAssignment(id: assignment.id, from: driveID)
            }
        }
    }

    private var activeOperation: UpdateOperationState? {
        store.operations.first { $0.assignmentID == assignment.id && $0.isActive }
    }

    private func setPolicy(_ policy: UpdatePolicy) {
        store.setUpdatePolicy(policy, forAssignment: assignment.id, on: driveID)
    }

    /// PRD F34: only one assignment of an entry+channel may track the latest.
    private var canTrackLatest: Bool {
        guard let drive = store.drive(id: driveID) else { return false }
        return store.canTrackLatest(assignmentID: assignment.id, on: drive)
    }

    private var pinHelp: String {
        guard assignment.isPinned else {
            return "Pin this version — Isotope stops updating it and never touches its file"
        }
        return canTrackLatest
            ? "Track the latest release again"
            : "Another assignment already tracks the latest release of this channel"
    }

    private var isManual: Bool {
        store.entry(id: assignment.entryID)?
            .channel(id: assignment.channelID)?.provider.mechanism == .windowsManual
    }

    private var isUpdatable: Bool {
        guard let drive = store.drive(id: driveID), store.isConnected(drive) else { return false }
        return store.release(for: assignment) != nil
    }

    private var updateHelp: String {
        guard let drive = store.drive(id: driveID) else { return "" }
        if !store.isConnected(drive) { return "Connect the drive to update it" }
        if store.release(for: assignment) == nil { return "No release resolved yet — check the catalog" }
        return isManual ? "Download this ISO from the vendor, then place it" : "Download and copy to this drive"
    }

    private func title(entry: CatalogEntry?, channel: Channel?) -> String {
        let name = entry?.name ?? assignment.entryID
        guard let channel, entry.map({ $0.channels.count > 1 }) == true else { return name }
        return "\(name) — \(channel.name)"
    }

    private func icon(for kind: CatalogEntry.Kind?) -> String {
        switch kind {
        case .linux: return "shippingbox"
        case .tool: return "wrench.and.screwdriver"
        case .windows: return "window.casement"
        case .custom: return "person.crop.square"
        case nil: return "questionmark.square.dashed"
        }
    }

    private var versionSummary: String {
        let installed = assignment.installed?.displayVersion ?? "Not installed"
        // PRD F33: a pinned row is about the version it holds, not the one it
        // is missing.
        guard !assignment.isPinned else { return "\(installed) · kept as is" }
        let latest = store.release(for: assignment)?.displayVersion ?? "unknown"
        return "\(installed) → \(latest)"
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch store.staleness(of: assignment) {
        case .pinned:
            Label("Pinned", systemImage: "pin.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .buildBehind:
            // Not an update: Microsoft services Windows monthly but reissues
            // the ISO rarely, so a newer build may not be downloadable at all.
            Text("Newer build shipped").font(.caption).foregroundStyle(.secondary)
                .help("This is the current release, but Microsoft has shipped a newer build of it. The download page may still offer the media you already have.")
        case .stale:
            Text("Update available").font(.caption).foregroundStyle(.orange)
        case .notInstalled:
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        case .unknown:
            Text("Unknown").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detected ISO row (PRD F41)

/// One recognised-but-untracked ISO: what Isotope thinks it is, and the two ways
/// to start tracking it. Nothing happens until one of the buttons is pressed.
private struct DetectedISORow: View {
    @Environment(AppStore.self) private var store
    let detected: DetectedISO
    let driveID: UUID

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detected.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // PRD F34: a second *tracker* for an entry+channel is refused, so
            // that button simply is not offered — pinning always is.
            adoptButton(title: "Track Latest", policy: .trackLatest,
                        help: "Create an assignment that keeps this ISO at the latest release")
            adoptButton(title: "Pin as Is", policy: .keepAsIs,
                        help: "Track this exact file and never replace it")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func adoptButton(title: String, policy: UpdatePolicy, help: String) -> some View {
        let choices = adoptableChannels(policy: policy)
        if choices.count == 1, let channel = choices.first {
            Button(title) { adopt(channelID: channel.id, policy: policy) }
                .help(help)
        } else if choices.count > 1 {
            // Ubuntu's LTS and Latest channels share one filename pattern: the
            // file says which image it is, not which channel should track it.
            Menu(title) {
                ForEach(choices) { channel in
                    Button(channel.name) { adopt(channelID: channel.id, policy: policy) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("\(help) — choose which channel it belongs to")
        }
    }

    private func adoptableChannels(policy: UpdatePolicy) -> [Channel] {
        guard let drive = store.drive(id: driveID) else { return [] }
        return store.channels(for: detected).filter {
            store.canAdopt(detected, channelID: $0.id, policy: policy, on: drive)
        }
    }

    private func adopt(channelID: String, policy: UpdatePolicy) {
        store.adoptDetectedISO(detected, channelID: channelID, policy: policy, on: driveID)
    }

    private var title: String {
        let entry = store.entry(id: detected.entryID)
        let name = entry?.name ?? detected.entryID
        let channels = store.channels(for: detected)
        // The channel is only worth naming when the entry has more than one, and
        // the file pins it down to a single one (AssignmentRow does the same).
        let channelName = channels.count == 1 && (entry?.channels.count ?? 0) > 1
            ? channels.first?.name : nil
        let base = [name, channelName].compactMap { $0 }.joined(separator: " — ")
        guard let version = detected.version?.raw else { return base }
        return "\(base) \(version)"
    }
}

/// Inline progress on the assignment row, so the user does not have to switch
/// to Activity to see that something is happening.
private struct OperationBadge: View {
    let operation: UpdateOperationState

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = operation.fractionCompleted {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(operation.isPaused ? "Paused" : operation.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add assignment

private struct AddAssignmentMenu: View {
    @Environment(AppStore.self) private var store
    let drive: ManagedDrive

    var body: some View {
        Menu {
            if store.allEntries.isEmpty {
                Text("The catalog is empty")
            } else {
                // PRD F38: the same organization grouping the Catalog view uses.
                ForEach(store.allEntries.groupedByOrganization(), id: \.organization) { group in
                    Section(group.organization) {
                        ForEach(group.entries) { entry in
                            entryMenu(entry)
                        }
                    }
                }
            }
        } label: {
            Label("Add Assignment", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func entryMenu(_ entry: CatalogEntry) -> some View {
        if entry.channels.count == 1, let channel = entry.channels.first {
            Button(entry.name) { add(entry: entry.id, channel: channel.id) }
                // PRD F34: a second *tracking* assignment of one entry+channel
                // is refused; adding one beside a pinned copy is fine.
                .disabled(!store.canAssign(entryID: entry.id, channelID: channel.id, to: drive))
        } else {
            Menu(entry.name) {
                ForEach(entry.channels) { channel in
                    Button(channel.name) { add(entry: entry.id, channel: channel.id) }
                        .disabled(!store.canAssign(entryID: entry.id, channelID: channel.id, to: drive))
                }
            }
        }
    }

    private func add(entry: String, channel: String) {
        store.addAssignment(entryID: entry, channelID: channel, to: drive.id)
    }
}
