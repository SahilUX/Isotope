import IsotopeCore
import SwiftUI

/// DESIGN §5 CatalogView: built-in and custom sections, each row showing the
/// resolved version, when it was checked, ISO size, a project link, and a
/// readable failure state when the last check failed (PRD F9/F14).
struct CatalogView: View {
    @Environment(AppStore.self) private var store

    @State private var editingEntry: CatalogEntry?
    @State private var isAddingSource = false
    @State private var deletionCandidate: CatalogEntry?

    var body: some View {
        List {
            // PRD F38: one section per organization, in catalog order, so
            // flavours (Kubuntu, Xubuntu…) live inside their family.
            ForEach(store.builtInEntries.groupedByOrganization(), id: \.organization) { group in
                section(title: group.organization, entries: group.entries)
            }
            customSection
        }
        .listStyle(.inset)
        .navigationTitle("Catalog")
        .toolbar {
            ToolbarItem {
                Button {
                    isAddingSource = true
                } label: {
                    Label("Custom Source", systemImage: "plus")
                }
                .help("Add a source the catalog doesn’t know about")
            }
            ToolbarItem {
                Button {
                    Task { await store.refreshCatalog() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(store.isCheckingCatalog)
            }
        }
        .overlay {
            // DESIGN §5 empty states: loading, failed and genuinely-empty read
            // differently — the first two are not the user's fault.
            if store.allEntries.isEmpty {
                if let error = store.lastLoadError {
                    ContentUnavailableView {
                        Label("Catalog could not be loaded", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.loadAtLaunch() } }
                    }
                } else if store.isCheckingCatalog {
                    ContentUnavailableView {
                        Label("Loading the catalog…", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Isotope is reading the bundled sources.")
                    }
                } else {
                    ContentUnavailableView("Catalog is empty",
                                           systemImage: "square.grid.2x2",
                                           description: Text("The bundled catalog contains no entries. Add a custom source to track an ISO yourself."))
                }
            }
        }
        .sheet(isPresented: $isAddingSource) {
            CustomSourceSheet(existing: nil)
        }
        .sheet(item: $editingEntry) { entry in
            CustomSourceSheet(existing: entry)
        }
        .confirmationDialog(deletionTitle, isPresented: deletionBinding, presenting: deletionCandidate) { entry in
            Button("Delete Source", role: .destructive) { store.removeCustomEntry(id: entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(deletionMessage(for: entry))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(title: String, entries: [CatalogEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    EntryCard(entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        Section("Custom") {
            if store.customEntries.isEmpty {
                Text("No custom sources yet. Add one to track an ISO the catalog doesn’t cover.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.customEntries) { entry in
                    EntryCard(entry: entry)
                        .contextMenu {
                            Button("Edit…") { editingEntry = entry }
                            Button("Delete…", role: .destructive) { deletionCandidate = entry }
                        }
                }
            }
        }
    }

    // MARK: - Deletion (PRD F11)

    private var deletionBinding: Binding<Bool> {
        Binding(get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } })
    }

    private var deletionTitle: String {
        deletionCandidate.map { "Delete “\($0.name)”?" } ?? "Delete source?"
    }

    private func deletionMessage(for entry: CatalogEntry) -> String {
        let drives = store.drivesUsing(entryID: entry.id)
        guard !drives.isEmpty else {
            return "This removes the source from the catalog. No files are deleted."
        }
        let names = drives.map(\.displayName).joined(separator: ", ")
        return "This source is assigned to \(names). Those assignments will stop updating. "
            + "No files on the drive are deleted."
    }
}

// MARK: - Rows

private struct EntryCard: View {
    @Environment(AppStore.self) private var store
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(entry.name).font(.headline)
                Spacer()
                if let homepage = entry.homepage {
                    Link("Project page", destination: homepage).font(.caption)
                }
            }
            ForEach(entry.channels) { channel in
                ChannelRow(entry: entry, channel: channel)
            }
        }
        .padding(.vertical, 4)
    }

    private var glyph: String {
        switch entry.kind {
        case .linux: return "shippingbox"
        case .tool: return "wrench.and.screwdriver"
        case .windows: return "window.casement"
        case .custom: return "person.crop.square"
        }
    }
}

private struct ChannelRow: View {
    @Environment(AppStore.self) private var store
    let entry: CatalogEntry
    let channel: Channel

    private var key: ReleaseKey { ReleaseKey(entryID: entry.id, channelID: channel.id) }

    var body: some View {
        let status = store.status(for: key)
        let release = store.release(for: key)

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if entry.channels.count > 1 {
                    Text(channel.name).font(.subheadline)
                }
                Text(MechanismCopy.summary(channel.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = status.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                versionLabel(status: status, release: release)
                if let release {
                    HStack(spacing: 6) {
                        if let size = release.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if !release.isVerifiable {
                            Text("unverified").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let checkedAt = status.checkedAt {
                    Text("checked \(checkedAt, format: .relative(presentation: .numeric))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, 26)
    }

    @ViewBuilder
    private func versionLabel(status: CheckStatus, release: Release?) -> some View {
        switch status {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("checking…").font(.callout).foregroundStyle(.secondary)
            }
        case .failed:
            Text(release?.displayVersion ?? "unknown")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ok, .never:
            Text(release?.displayVersion ?? "not checked")
                .font(.callout.monospacedDigit())
                .foregroundStyle(release == nil ? .secondary : .primary)
        }
    }
}

/// One-line explanations of each mechanism, shared by the catalog rows and the
/// custom-source picker (PRD §5).
enum MechanismCopy {
    static func title(_ mechanism: ProviderConfig.Mechanism) -> String {
        switch mechanism {
        case .checksumFile: return "Checksum file"
        case .gitHubReleases: return "GitHub Releases"
        case .staticURL: return "Static URL"
        case .pageScrape: return "Page scrape"
        case .jsonFeed: return "Release feed"
        case .windowsManual: return "Windows (manual)"
        }
    }

    static func explanation(_ mechanism: ProviderConfig.Mechanism) -> String {
        switch mechanism {
        case .checksumFile:
            return "Reads a SHA256SUMS-style file: filename, version and checksum in one request. Best when the project publishes one."
        case .gitHubReleases:
            return "Uses the GitHub Releases API: version from the tag, ISO from a matching asset, checksum from a sibling .sha256 asset."
        case .staticURL:
            return "A URL that never changes but whose file does. Compares ETag / Last-Modified, so the “version” is a change date."
        case .pageScrape:
            return "Reads links from a download or directory page and picks the highest version. Most fragile — use Test to check the pattern."
        case .jsonFeed:
            return "Reads a project’s machine-readable release feed. Built-in catalog entries only."
        case .windowsManual:
            return "Tracks the current Windows build; the download itself stays manual because Microsoft’s links expire."
        }
    }

    /// Short per-row summary of where a channel gets its data.
    static func summary(_ config: ProviderConfig) -> String {
        switch config {
        case .checksumFile(let url, _, let index, _):
            return "Checksum file · \(host(index?.url ?? url))"
        case .gitHubReleases(let repo, _):
            return "GitHub Releases · \(repo)"
        case .staticURL(let url, _, _):
            return "Static URL · \(host(url))"
        case .pageScrape(let url, _, let index, _):
            return "Page scrape · \(host(index?.url ?? url))"
        case .jsonFeed(let url, _, _):
            return "Release feed · \(host(url))"
        case .windowsManual(let infoURL, _, _, _, _, _):
            return "Manual download · \(host(infoURL))"
        }
    }

    private static func host(_ url: URL) -> String { url.host() ?? url.absoluteString }
}
