import SwiftUI

/// Keep fleet observation separate from the main window's large view tree.
struct MDMFleetViewObserver: ViewModifier {
    let selection: Set<Int>
    let filter: SidebarFilter
    @Binding var connectPanelVisible: Bool
    @EnvironmentObject private var settings: SettingsStore
    @Environment(MDMFleetIndex.self) private var fleet
    @Environment(BlueSkyHostListStore.self) private var hosts

    func body(content: Content) -> some View {
        content
            .onChange(of: selection) { _, selected in
                if [.mdmDashboard, .mdmDevices, .mdmSecurity, .mdmUpdates].contains(filter), !selected.isEmpty {
                    connectPanelVisible = true
                    UserDefaults.standard.set("mdm", forKey: "connectPanelTab")
                }
            }
            .onChange(of: settings.mdmRequireFileVault) { _, _ in rebuild() }
            .onChange(of: settings.mdmMinOSVersion) { _, _ in rebuild() }
    }

    private func rebuild() {
        fleet.rebuildIndex(settings: settings,
                           bscSerials: Set(hosts.hosts.compactMap { $0.serialnum?.uppercased() }))
    }
}
