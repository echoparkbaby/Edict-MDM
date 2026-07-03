import SwiftUI

// Alert construction split out of the (very large) ContentView. Pure view
// logic — builds `Alert` values from the `AlertContent` enum and formats the
// bulk-confirmation message. Behavior unchanged; this only moves code out of
// the main file. Members it touches (`AlertContent`, `runAction`, `runBulk`)
// are internal so this same-type extension can reach them across files.
extension ContentView {
    func alertView(for content: AlertContent) -> Alert {
        switch content {
        case .singleAction(let host, .selfdestruct):
            return Alert(
                title: Text("Send Delete Command?"),
                message: Text("Setting selfdestruct=1 on \(host.displayName) (#\(host.blueskyid)). The Mac client will uninstall itself on next check-in. The DB row stays."),
                primaryButton: .destructive(Text("Send")) { runAction(.selfdestruct, on: host) },
                secondaryButton: .cancel()
            )
        case .singleAction(let host, .delete):
            return Alert(
                title: Text("Delete Permanently?"),
                message: Text("Removes \(host.displayName) (#\(host.blueskyid)) from the BlueSky database AND scrubs the corresponding pubkey. This is irreversible."),
                primaryButton: .destructive(Text("Delete")) { runAction(.delete, on: host) },
                secondaryButton: .cancel()
            )
        case .singleAction(let host, .block):
            let serial = (host.serialnum ?? "—")
            return Alert(
                title: Text("Block Host Permanently?"),
                message: Text("""
                    Adds serial \(serial) to the BSC server's blocked_serials list, installs a DB trigger that rejects any future registration with that serial, and runs the same teardown as Delete (scrub key, drop row).

                    Use this for \(host.displayName) (#\(host.blueskyid)) when the Mac is out of your control (sold, transferred) and you can't uninstall BlueSky on the client. The agent will keep retrying — the server will keep refusing.

                    Reversible only by removing the serial from blocked_serials manually on the BSC server.
                    """),
                primaryButton: .destructive(Text("Block Forever")) { runAction(.block, on: host) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .selfdestruct):
            return Alert(
                title: Text("Send Delete Command to \(hosts.count) Hosts?"),
                message: Text(bulkMessage(hosts: hosts, base: "Each Mac client will uninstall itself on next check-in.")),
                primaryButton: .destructive(Text("Send to \(hosts.count)")) { runBulk(.selfdestruct, on: hosts) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .delete):
            return Alert(
                title: Text("Delete \(hosts.count) Hosts?"),
                message: Text(bulkMessage(hosts: hosts, base: "Removes the rows from the DB AND scrubs each pubkey. Irreversible.")),
                primaryButton: .destructive(Text("Delete \(hosts.count)")) { runBulk(.delete, on: hosts) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .block):
            return Alert(
                title: Text("Block \(hosts.count) Hosts Permanently?"),
                message: Text(bulkMessage(hosts: hosts, base: "Adds each host's serial to BlueSky.blocked_serials, scrubs key + row, and refuses any future re-registration with the same serial. Reversible only via the BSC server.")),
                primaryButton: .destructive(Text("Block \(hosts.count)")) { runBulk(.block, on: hosts) },
                secondaryButton: .cancel()
            )
        case .result(let title, let message):
            return Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("OK")))
        case .error(let msg):
            return Alert(title: Text("Error"), message: Text(msg), dismissButton: .default(Text("OK")))
        }
    }

    func bulkMessage(hosts: [BlueSkyHost], base: String) -> String {
        let names = hosts.prefix(5).map { "#\($0.blueskyid) \($0.displayName)" }.joined(separator: "\n")
        let suffix = hosts.count > 5 ? "\n…and \(hosts.count - 5) more" : ""
        return "\(base)\n\n\(names)\(suffix)"
    }
}
