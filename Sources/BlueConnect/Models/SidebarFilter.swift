import Foundation

enum SidebarFilter: Hashable {
    case all
    case favorites
    case recent
    case active
    case inactive
    case uncategorized
    case category(String)
    /// Edict MDM: swaps the center pane to the KMFDDM declarations
    /// browser instead of filtering the hosts table.
    case mdmDeclarations
    /// Edict MDM: swaps the center pane to the managed-devices view.
    case mdmDevices

    var key: String {
        switch self {
        case .all: "all"
        case .favorites: "fav"
        case .recent: "recent"
        case .active: "active"
        case .inactive: "inactive"
        case .uncategorized: "uncat"
        case .category(let c): "cat:\(c)"
        case .mdmDeclarations: "mdm:decl"
        case .mdmDevices: "mdm:dev"
        }
    }
}
