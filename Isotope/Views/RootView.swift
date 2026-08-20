import SwiftUI

/// Navigation shell (DESIGN §5): sidebar Drives / Catalog / Activity / Settings.
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            // Rows are tagged values rather than `NavigationLink(value:)`: the
            // detail column switches on `store.selection` itself instead of
            // declaring a `navigationDestination`, and tagging is the pattern
            // that pairs with a selection-driven detail.
            List(selection: $store.selection) {
                Section("Drives") {
                    Label("All Drives", systemImage: "externaldrive")
                        .tag(SidebarSelection.drives)
                    ForEach(store.drives) { drive in
                        // Per-drive status dot (DESIGN §5, PRD F2).
                        Label {
                            HStack(spacing: 6) {
                                Text(drive.displayName)
                                Spacer(minLength: 4)
                                DriveStatusDot(status: store.status(of: drive))
                            }
                        } icon: {
                            Image(systemName: store.isConnected(drive)
                                  ? "externaldrive.fill" : "externaldrive")
                        }
                        .tag(SidebarSelection.drive(drive.id))
                    }
                }
                Section {
                    Label("Catalog", systemImage: "square.grid.2x2")
                        .tag(SidebarSelection.catalog)
                    Label("Activity", systemImage: "arrow.down.circle")
                        .tag(SidebarSelection.activity)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarSelection.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            // The detail column carries its own minimum; together with the
            // sidebar's it gives the window a sane floor without ever making the
            // split view wider than the window (see `IsotopeApp`).
            detail.frame(minWidth: 560, minHeight: 420)
        }
        .navigationTitle("Isotope")
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .drives, .none:
            DrivesView()
        case .drive(let id):
            DriveDetailView(driveID: id)
        case .catalog:
            CatalogView()
        case .activity:
            ActivityView()
        case .settings:
            SettingsView()
        }
    }
}
