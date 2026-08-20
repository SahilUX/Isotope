import IsotopeCore
import SwiftUI

/// DESIGN §5 CustomSourceSheet / PRD F10: name, mechanism picker with a one-line
/// explanation each, mechanism-specific fields, and a **Test** button that runs
/// the provider live and shows the parsed result before Save.
///
/// Only the four user-facing mechanisms of PRD §5 are offered; `jsonFeed` and
/// `windowsManual` exist for built-in entries and are not user-authorable.
struct CustomSourceSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    static let userMechanisms: [ProviderConfig.Mechanism] =
        [.checksumFile, .gitHubReleases, .staticURL, .pageScrape]

    let existing: CatalogEntry?

    @State private var name = ""
    @State private var homepage = ""
    @State private var mechanism: ProviderConfig.Mechanism = .checksumFile
    @State private var url = ""
    @State private var pattern = ""
    @State private var repo = ""
    @State private var checksumURL = ""
    @State private var checksumSuffix = ""
    @State private var downloadBase = ""

    @State private var testState: TestState = .idle

    private enum TestState {
        case idle
        case running
        case success(Release)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New Custom Source" : "Edit Custom Source")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. SystemRescue"))
                    TextField("Project page", text: $homepage, prompt: Text("https:// (optional)"))
                }

                Section("How should Isotope find the latest version?") {
                    Picker("Mechanism", selection: $mechanism) {
                        ForEach(Self.userMechanisms, id: \.self) { mechanism in
                            Text(MechanismCopy.title(mechanism)).tag(mechanism)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(MechanismCopy.explanation(mechanism))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section { mechanismFields }

                Section { testResult }
            }
            .formStyle(.grouped)
            .onChange(of: mechanism) { testState = .idle }

            Divider()
            HStack {
                Button("Test") { runTest() }
                    .disabled(!canTest || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: loadExisting)
    }

    // MARK: - Fields

    @ViewBuilder
    private var mechanismFields: some View {
        switch mechanism {
        case .checksumFile:
            TextField("Checksum file URL", text: $url,
                      prompt: Text("https://example.org/current/SHA256SUMS"))
            patternField("Filename pattern", hint: #"foo-(\d+\.\d+)-amd64\.iso"#)
            TextField("Download base URL", text: $downloadBase,
                      prompt: Text("optional — only if the ISO isn’t next to the checksum file"))
        case .gitHubReleases:
            TextField("Repository", text: $repo, prompt: Text("owner/name"))
            patternField("Asset name pattern", hint: #"\.iso$"#)
        case .staticURL:
            TextField("ISO URL", text: $url, prompt: Text("https://example.org/latest/foo.iso"))
            TextField("Checksum URL", text: $checksumURL,
                      prompt: Text("optional — without it downloads are marked unverified"))
        case .pageScrape:
            TextField("Page URL", text: $url, prompt: Text("https://example.org/download/"))
            patternField("Link pattern", hint: #"foo-(\d+\.\d+)\.iso$"#)
            TextField("Checksum suffix", text: $checksumSuffix,
                      prompt: Text("optional — e.g. .sha256, appended to the ISO URL"))
        case .jsonFeed, .windowsManual:
            Text("This mechanism is only used by built-in catalog entries.")
                .foregroundStyle(.secondary)
        }
    }

    private func patternField(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $pattern, prompt: Text(hint))
                .font(.body.monospaced())
            Text("A regular expression. The first capture group is the version.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Test result (PRD F10, DESIGN §6 "regex matches nothing")

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            Text("Run Test to see what this source resolves to before saving.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running:
            Label("Checking the source…", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .success(let release):
            VStack(alignment: .leading, spacing: 4) {
                Label("Resolved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                LabeledContent("Version", value: release.version.raw)
                LabeledContent("File", value: release.fileName.isEmpty ? "—" : release.fileName)
                LabeledContent("URL", value: release.isoURL?.absoluteString ?? "—")
                LabeledContent("Checksum",
                               value: release.isVerifiable
                                   ? "found (SHA-256)"
                                   : "none — downloads will be marked unverified")
                if let size = release.sizeBytes {
                    LabeledContent("Size",
                                   value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Check failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - State

    private var isTesting: Bool { if case .running = testState { return true }; return false }

    private var canTest: Bool { buildConfig() != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && buildConfig() != nil
    }

    private func loadExisting() {
        guard let existing, let channel = existing.channels.first else { return }
        name = existing.name
        homepage = existing.homepage?.absoluteString ?? ""
        mechanism = channel.provider.mechanism
        switch channel.provider {
        case .checksumFile(let u, let p, _, let base):
            url = u.absoluteString; pattern = p; downloadBase = base?.absoluteString ?? ""
        case .gitHubReleases(let r, let p):
            repo = r; pattern = p
        case .staticURL(let u, let c, _):
            url = u.absoluteString; checksumURL = c?.absoluteString ?? ""
        case .pageScrape(let u, let p, _, let suffix):
            url = u.absoluteString; pattern = p; checksumSuffix = suffix ?? ""
        case .jsonFeed, .windowsManual:
            break
        }
    }

    private func buildConfig() -> ProviderConfig? {
        func link(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return url
        }
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        // A malformed regex must not reach the provider as a runtime surprise.
        guard mechanism == .staticURL || (!trimmedPattern.isEmpty
                                          && (try? PatternMatcher(trimmedPattern)) != nil) else { return nil }

        switch mechanism {
        case .checksumFile:
            guard let target = link(url) else { return nil }
            return .checksumFile(url: target, filePattern: trimmedPattern,
                                 downloadBase: link(downloadBase))
        case .gitHubReleases:
            let path = repo.trimmingCharacters(in: .whitespaces)
            guard path.split(separator: "/").count == 2 else { return nil }
            return .gitHubReleases(repo: path, assetPattern: trimmedPattern)
        case .staticURL:
            guard let target = link(url) else { return nil }
            return .staticURL(url: target, checksumURL: link(checksumURL))
        case .pageScrape:
            guard let target = link(url) else { return nil }
            let suffix = checksumSuffix.trimmingCharacters(in: .whitespaces)
            return .pageScrape(url: target, linkPattern: trimmedPattern,
                               checksumSuffix: suffix.isEmpty ? nil : suffix)
        case .jsonFeed, .windowsManual:
            return nil
        }
    }

    private func runTest() {
        guard let config = buildConfig() else { return }
        testState = .running
        Task {
            switch await store.testProvider(config) {
            case .success(let release): testState = .success(release)
            case .failure(let message): testState = .failure(message)
            }
        }
    }

    private func save() {
        guard let config = buildConfig() else { return }
        let id = existing?.id ?? "custom-\(UUID().uuidString)"
        let entry = CatalogEntry(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: .custom,
            homepage: URL(string: homepage.trimmingCharacters(in: .whitespaces)),
            channels: [Channel(id: "default", name: "Default", provider: config)],
            isBuiltIn: false
        )
        store.addCustomEntry(entry)
        dismiss()
    }
}
