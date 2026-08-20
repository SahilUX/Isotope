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

    let item: UpdatePlanItem
    let downloadPage: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
            watcher.pattern = Self.pattern(for: item)
            watcher.start()
        }
        .onDisappear { watcher.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Get \(item.title) \(item.toVersion)").font(.headline)
            Text("Microsoft's download links are generated per session and expire, so this one step is manual.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Open Microsoft's download page and choose the ISO for x64.")
            step(2, "Save it to your Downloads folder — Isotope is watching for it.")
            step(3, "Compare the checksum Microsoft shows with the one Isotope computes, then place it on “\(item.driveName)”.")
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
            if watcher.candidates.isEmpty {
                Text("No matching ISO yet. Isotope re-checks every few seconds — or use Choose File… to point at it yourself.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(watcher.candidates) { candidate in
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
    static func pattern(for item: UpdatePlanItem) -> String {
        let stem = item.title.split(separator: " ").first.map(String.init) ?? "Win"
        let escaped = NSRegularExpression.escapedPattern(for: stem)
        return "(?i)^\(escaped).*\\.iso$"
    }
}
