import AppKit
import IsotopeCore
import SwiftUI

struct LocalFilesView: View {
    @Environment(AppStore.self) private var store
    @State private var flashPlan: FlashPlan?
    @State private var copyChoice: CopyChoice?
    @State private var error: String?

    private struct CopyChoice: Identifiable {
        var id = UUID()
        var file: LocalFile
        var drive: ManagedDrive
    }

    var body: some View {
        List {
            Section {
                Text("Choose files from your Mac to open or copy to a USB drive. ISO and IMG images can also be flashed. Your original files are kept.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.localFiles) { file in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(file.name, systemImage: "doc")
                            .font(.headline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Open") {
                            if !NSWorkspace.shared.open(file.url) { error = "macOS could not open this file." }
                        }
                        Menu("Copy to USB…") {
                            ForEach(copyDrives) { drive in
                                Button(drive.displayName) { copyChoice = CopyChoice(file: file, drive: drive) }
                                    .disabled(store.hasOperationsInFlight(drive))
                            }
                            if copyDrives.isEmpty {
                                Text("Register a mounted USB drive in All Drives first")
                            }
                        }
                        Menu("Flash USB…") {
                            ForEach(store.localFlashDevices) { device in
                                Button("\(device.displayName) · \(device.subtitle)") {
                                    perform { flashPlan = try store.localFlashPlan(file, device: device) }
                                }
                            }
                            if store.localFlashDevices.isEmpty { Text("Connect a USB device, or unregister its copy-drive entry first") }
                        }
                        .disabled(!file.canFlash)
                        Spacer()
                        Button("Remove") { store.localFiles.removeAll { $0.id == file.id } }
                            .help("Remove from this list; the file stays on disk")
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Local Files")
        .toolbar {
            Button { chooseFiles() } label: { Label("Choose Files…", systemImage: "plus") }
        }
        .overlay {
            if store.localFiles.isEmpty {
                ContentUnavailableView {
                    Label("Bring your own files", systemImage: "doc.badge.plus")
                } description: {
                    Text("Use files you already have, including images outside the catalog.")
                } actions: {
                    Button("Choose Files…") { chooseFiles() }
                }
                .allowsHitTesting(true)
            }
        }
        .sheet(item: $flashPlan) { plan in
            FlashConfirmationSheet(plan: plan, verifyByDefault: store.settings.flashVerification) { verify in
                perform { try store.startLocalFlash(plan, verify: verify) }
            }
        }
        .sheet(item: $copyChoice) { choice in
            VStack(alignment: .leading, spacing: 16) {
                Text("Copy “\(choice.file.name)” to “\(choice.drive.displayName)”? ").font(.headline)
                Text("The file will be copied into this drive's configured folder: \(choice.drive.isoFolder.isEmpty ? "/" : choice.drive.isoFolder). Your original is kept. An existing file with the same name will not be replaced.")
                HStack {
                    Spacer()
                    Button("Cancel") { copyChoice = nil }.keyboardShortcut(.cancelAction)
                    Button("Copy") {
                        perform { try store.copyLocalFile(choice.file, to: choice.drive.id) }
                        copyChoice = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 480)
        }
        .alert("File action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var copyDrives: [ManagedDrive] {
        store.drives.filter { !$0.isFlashed && store.isConnected($0) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Files"
        panel.begin { response in
            guard response == .OK else { return }
            perform { try store.importLocalFiles(panel.urls) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
