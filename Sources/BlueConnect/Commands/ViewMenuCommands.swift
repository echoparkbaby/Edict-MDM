import SwiftUI

/// Replaces both the auto-injected View menu and the previous one-item
/// custom one (just "Show Log"). Adds sidebar/pane toggles, sidebar
/// filter shortcuts, and a Sort-by submenu.
///
/// Filter and sort actions are routed through `HostActions` so ContentView
/// remains the single owner of that state (sidebar selection + sortOrder).
struct ViewMenuCommands: Commands {
    @Bindable var terminals: TerminalSessionsManager
    @AppStorage("mdmEnabled") private var mdmEnabled = false
    @FocusedValue(\.hostActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .toolbar) {
            Button("Show Log") { terminals.activeSelection = .log }
                .keyboardShortcut("\\", modifiers: [.command])

            Divider()

            // ⌃⌘S / ⌃⌘P — chosen to avoid ⌘B (Bold in any text field) and
            // ⌥⌘B (Bold-italic in some apps). ⌃⌘S mirrors Mail's Hide/Show
            // Sidebar; ⌃⌘P is "Panel". The Bottom Pane toggle was dropped
            // because it was a no-op while sessions/tunnels existed —
            // bottom-pane visibility is derived from content presence.
            Toggle("Sidebar", isOn: Binding(
                get: { actions?.isSidebarVisible ?? true },
                set: { _ in actions?.toggleSidebar() }
            ))
            .keyboardShortcut("s", modifiers: [.control, .command])

            Toggle("Connect Panel", isOn: Binding(
                get: { actions?.isConnectPanelVisible ?? true },
                set: { _ in actions?.toggleConnectPanel() }
            ))
            .keyboardShortcut("p", modifiers: [.control, .command])

            Divider()

            if mdmEnabled {
                Menu("Device Management") {
                    Button("Overview") { actions?.setSidebarFilter(.mdmDashboard) }
                    Button("Devices") { actions?.setSidebarFilter(.mdmDevices) }
                    Button("Security") { actions?.setSidebarFilter(.mdmSecurity) }
                    Button("Updates") { actions?.setSidebarFilter(.mdmUpdates) }
                    Button("Policies") { actions?.setSidebarFilter(.mdmProfiles) }
                    Button("Enrollment") { actions?.setSidebarFilter(.mdmEnrollment) }
                    Button("Activity") { actions?.setSidebarFilter(.mdmActivity) }
                }
                Divider()
            }
            Section("Remote Support") {
                Button("All Hosts") { actions?.setSidebarFilter(.all) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Favorites") { actions?.setSidebarFilter(.favorites) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Recently Connected") { actions?.setSidebarFilter(.recent) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Active") { actions?.setSidebarFilter(.active) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Button("Inactive") { actions?.setSidebarFilter(.inactive) }
                    .keyboardShortcut("5", modifiers: [.command, .option])
                Button("Uncategorized") { actions?.setSidebarFilter(.uncategorized) }
                    .keyboardShortcut("6", modifiers: [.command, .option])
            }

            Divider()

            Menu("Sort By") {
                Button("Hostname") { actions?.setSortField("name") }
                Button("ID")       { actions?.setSortField("id") }
                Button("Status")   { actions?.setSortField("status") }
                Button("Last Seen") { actions?.setSortField("last_seen") }
            }

            // Migrated from the old toolbar ⋯ menu. Dividers above and
            // below isolate it visually from Sort By + whatever menu
            // SwiftUI auto-appends below this group.
            Divider()
            Button("Customize Row Icons…") { actions?.showCustomizeRowIcons() }
                .disabled(actions == nil)
            Divider()
        }
    }
}
