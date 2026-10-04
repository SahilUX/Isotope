import AppKit
import IsotopeCore
import SwiftUI
import UniformTypeIdentifiers

/// PRD §5.4 / F21. Microsoft generates one-shot download links, so Isotope
/// tracks the build, sends the user to the official page, watches `~/Downloads`
/// for the ISO to appear, shows its computed SHA-256 for manual comparison, and
/// then places it on the drive with the normal pipeline.
struct WindowsManualSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var watcher = DownloadsWatcher()
    @State private var selected: FoundISO?
    @State private var hash: String?
    @State private var isHashing = false
    @State private var hashError: String?
    /// PRD F49: where the opt-in "ask Microsoft directly" attempt has got to.
    @State private var attempt: AutoAttempt = .notTried

    /// The attempt has exactly three honest outcomes, and the sheet says which.
    private enum AutoAttempt: Equatable {
        case notTried
        case trying
        /// Microsoft answered with a link; the normal pipeline has it now.
        case started(String)
        /// Refused or failed. Carries Microsoft's own words where they gave any;
        /// the manual steps below stand either way.
        case refused(String)
    }

    let item: UpdatePlanItem
    let downloadPage: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    autoAttemptSection
                    steps
                    Divider()
                    foundSection
                    if let selected, !watcher.candidates.contains(selected) {
                LabeledContent("Chosen file") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selected.fileName)
                        Text(ByteCountFormatter.string(fromByteCount: selected.sizeBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let hash { hashSection(hash) }
                    if let hashError {
                        Text(hashError).font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 500)
        .frame(maxHeight: 560)
        .onAppear {
            watcher.pattern = Self.pattern(
                for: item,
                catalogPattern: store.mediaFileNamePattern(entryID: item.entryID,
                                                           channelID: item.channelID))
            watcher.excludedPatterns = store.otherMediaFileNamePatterns(excludingEntryID: item.entryID)
            watcher.start()
            tryAutomaticDownload()
        }
        .onDisappear { watcher.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Get \(item.title) \(item.toVersion)").font(.headline)
            Text("Microsoft's download links are generated per session and expire, so this one step is manual.")
                .font(.callout).foregroundStyle(.secondary)
            // PRD F46 amendment: say what this download will actually get you,
            // rather than letting the version arrow imply a newer ISO exists.
            if item.isBuildOnlyDifference {
                Text("You already have the current media for this release. The newer build ships through Windows Update, not in the ISO, so the download page will most likely hand you the same file. Downloading it again is harmless — Isotope reads the build out of whatever you save and will show it here.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// PRD F49. Shown only when the user turned the attempt on: it is off by
    /// default because Microsoft refuses it far more often than not, and a
    /// permanently failing spinner would be worse than no attempt at all.
    @ViewBuilder
    private var autoAttemptSection: some View {
        switch attempt {
        case .notTried:
            EmptyView()
        case .trying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking Microsoft for a direct download link…").font(.callout)
            }
        case .started(let fileName):
            VStack(alignment: .leading, spacing: 4) {
                Label("Microsoft answered — downloading “\(fileName)”", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Text("It is being downloaded, checksum-verified and placed on “\(item.driveName)” like any other ISO. You can close this window; progress is in Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .refused(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Microsoft refused the automated request", systemImage: "hand.raised.fill")
                    .font(.callout).foregroundStyle(.orange)
                Text(reason)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Their download service rejects clients that are not a browser, which is why this stays a manual step. Carry on below — it is three clicks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Open Microsoft's download page and choose the ISO for x64.")
            step(2, "Save it to your Downloads folder — Isotope is watching for it.")
            step(3, "Compare the checksum Microsoft shows with the one Isotope computes, then place it on “\(item.driveName)”.")
            if store.settings.trashManualSourceAfterPlacement {
                Text("Once it is on the drive, the download is moved to the Trash — Settings ▸ Windows turns that off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let downloadPage {
                Button("Open Microsoft Download Page", systemImage: "safari") {
                    NSWorkspace.shared.open(downloadPage)
                }
                .padding(.top, 4)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("In your Downloads folder").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Rescan") { watcher.scan() }.buttonStyle(.link).font(.caption)
                // The watch matches a filename pattern; if the user renamed the
                // ISO or saved it elsewhere, picking it by hand always works.
                Button("Choose File…") { chooseFile() }.buttonStyle(.link).font(.caption)
            }
            if !watcher.folderIsReadable {
                Text("Isotope could not read your Downloads folder. Grant it access in System Settings → Privacy & Security → Files and Folders, or use Choose File… to point at the ISO directly.")
                    .font(.callout).foregroundStyle(.orange)
            } else if watcher.candidates.isEmpty, watcher.otherISOs.isEmpty {
                Text("No ISO here yet. Isotope re-checks every few seconds — or use Choose File… to point at it yourself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if watcher.candidates.isEmpty, !watcher.otherISOs.isEmpty {
                Text("Nothing here is named the way Microsoft names this image, so these are the other ISOs in the folder, newest first — leaving out ones Isotope recognises as a different image. Pick the one you downloaded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(watcher.candidates + watcher.otherISOs) { candidate in
                    HStack {
                        Image(systemName: selected == candidate ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == candidate ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.fileName)
                            Text(ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = candidate
                        hash = nil
                        hashError = nil
                    }
            }
        }
    }

    private func hashSection(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SHA-256 of the downloaded file").font(.subheadline.weight(.semibold))
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Compare this with the checksum Microsoft publishes for the build you downloaded. Isotope cannot verify it for you.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if selected != nil {
                Button(isHashing ? "Computing…" : "Compute Checksum") { computeHash() }
                    .disabled(isHashing)
            }
            Spacer()
            Button("Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Place on Drive") { place() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || isHashing)
        }
        .padding(16)
    }

    /// PRD F49: try the direct link before falling back to the hand-off. The
    /// store returns nil when the setting is off, so this is a no-op for
    /// everyone who never turned it on.
    private func tryAutomaticDownload() {
        guard store.settings.attemptWindowsAutoDownload, attempt == .notTried else { return }
        attempt = .trying
        Task {
            switch await store.attemptWindowsDownload(for: item) {
            case .resolved(let resolved):
                store.startResolvedWindowsDownload(resolved, for: item)
                attempt = .started(resolved.fileName)
            case .refused(let reason), .failed(let reason):
                attempt = .refused(reason)
            }
        }
    }

    /// PRD §5.4 alternative to the pattern watch: pick the downloaded ISO
    /// directly. The open panel is also what grants the sandbox access to it.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose ISO"
        panel.message = "Choose the ISO you downloaded from the vendor."
        panel.prompt = "Use ISO"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = watcher.folder
        if let iso = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [iso]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        selected = FoundISO(url: url, fileName: url.lastPathComponent,
                            sizeBytes: Int64(values?.fileSize ?? 0),
                            modifiedAt: values?.contentModificationDate ?? Date())
        hash = nil
        hashError = nil
    }

    private func computeHash() {
        guard let selected else { return }
        isHashing = true
        hashError = nil
        let hashing = store.hashing
        let url = selected.url
        Task {
            let digest = await Task.detached(priority: .userInitiated) {
                try? hashing.sha256Hex(ofFileAt: url)
            }.value
            await MainActor.run {
                isHashing = false
                if let digest {
                    hash = digest
                } else {
                    hashError = "The file could not be read. If it is still downloading, wait for it to finish."
                }
            }
        }
    }

    private func place() {
        guard let selected else { return }
        store.placeManualISO(selected, for: item)
        dismiss()
    }

    /// Match what the vendor actually names the file, loosely enough to survive
    /// a naming change: any ISO starting with the entry's first word.
    /// What to watch for in Downloads.
    ///
    /// The catalog already carries the pattern that recognises this channel's
    /// media on a drive (PRD F41), and that is the authority — deriving one from
    /// the entry's *title* was the bug this replaces: "Windows 11" gave
    /// `^Windows.*\.iso$`, which never matches Microsoft's own
    /// `Win11_25H2_English_x64_v2.iso`, so a downloaded ISO sat in the folder
    /// unseen.
    ///
    /// The fallback stays deliberately loose, because a pattern that misses is
    /// worse than one that offers too much: anything unmatched is still listed
    /// as an "other ISO" for the user to pick.
    static func pattern(for item: UpdatePlanItem, catalogPattern: String?) -> String {
        catalogPattern ?? #"(?i)^win.*\.iso$"#
    }
}
