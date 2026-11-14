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
    case mdmSecurity
    case mdmUpdates
    case mdmActivity
    /// Edict MDM: configuration-profile library.
    case mdmProfiles
    /// Edict MDM: enrollment-profile builder.
    case mdmEnrollment
    /// Edict MDM: Automated Device Enrollment (DEP / Apple Business Manager).
    case mdmDEP
    /// Edict MDM: scheduled automation.
    case mdmScheduling
    /// Edict MDM: fleet/group compliance dashboard.
    case mdmDashboard

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
        case .mdmSecurity: "mdm:security"
        case .mdmUpdates: "mdm:updates"
        case .mdmActivity: "mdm:activity"
        case .mdmProfiles: "mdm:prof"
        case .mdmEnrollment: "mdm:enroll"
        case .mdmDEP: "mdm:dep"
        case .mdmScheduling: "mdm:sched"
        case .mdmDashboard: "mdm:dash"
        }
    }
}
