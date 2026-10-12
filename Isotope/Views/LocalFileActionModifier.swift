import AppKit
import IsotopeCore
import SwiftUI

/// The local-file action stays with the drive's image menu.
struct LocalFileActionModifier: ViewModifier {
    @Environment(AppStore.self) private var store
    let drive: ManagedDrive
    @Binding var choosingFile: Bool
    @State private var flashPlan: FlashPlan?
    @State private var copyFile: LocalFile?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: choosingFile) { _, choosing in
                guard choosing else { return }
                choosingFile = false
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose File"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                perform {
                    let file = try LocalFile(url: url)
                    if drive.isFlashed {
                        guard let device = store.attachedDevice(for: drive) else {
                            throw LocalFileError.unavailableDrive
                        }
                        flashPlan = try store.localFlashPlan(file, device: device)
                    } else {
                        copyFile = file
                    }
                }
            }
            .sheet(item: $flashPlan) { plan in
                FlashConfirmationSheet(plan: plan, verifyByDefault: store.settings.flashVerification) { verify in
                    perform { try store.startLocalFlash(plan, verify: verify) }
                }
            }
            .sheet(item: $copyFile) { file in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copy “\(file.name)” to “\(drive.displayName)”? ").font(.headline)
                    Text("The file will be copied into this drive's configured folder: \(drive.isoFolder.isEmpty ? "/" : drive.isoFolder). Your original is kept. An existing file with the same name will not be replaced.")
                    HStack {
                        Spacer()
                        Button("Cancel") { copyFile = nil }.keyboardShortcut(.cancelAction)
                        Button("Copy") {
                            perform { try store.copyLocalFile(file, to: drive.id) }
                            copyFile = nil
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 480)
            }
            .alert("File action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
