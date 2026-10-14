import Foundation

/// Computes a human-readable diff between two configuration profiles —
/// "what's about to change" when an operator re-deploys a profile that a
/// device already has. Compares payload key/values, ignoring the volatile
/// UUID/identifier fields Edict regenerates on every build so the diff
/// shows real policy changes, not churn.
enum ProfileDiff {
    struct Change: Identifiable, Hashable {
        var id = UUID()
        enum Kind: String { case added = "Added", removed = "Removed", changed = "Changed" }
        var kind: Kind
        var path: String      // "FileVault Encryption → Defer"
        var before: String?
        var after: String?
    }

    /// Top-level dict of a .mobileconfig (signed or plain XML).
    static func decode(_ data: Data) -> [String: Any]? {
        guard let plistData = CMSProfile.plistData(data) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    }

    /// The diff between an already-deployed profile and a new one. Runs off
    /// the main actor — `decode` shells out to `security cms -D` for signed
    /// profiles, and this is called from MainActor deploy paths.
    static func compare(old: Data, new: Data) async -> [Change] {
        await Task.detached(priority: .userInitiated) {
            let o = flatten(decode(old))
            let n = flatten(decode(new))
            var changes: [Change] = []
            for key in Set(o.keys).union(n.keys).sorted() {
                switch (o[key], n[key]) {
                case let (a?, b?) where a != b:
                    changes.append(Change(kind: .changed, path: key, before: a, after: b))
                case let (a?, nil):
                    changes.append(Change(kind: .removed, path: key, before: a, after: nil))
                case let (nil, b?):
                    changes.append(Change(kind: .added, path: key, before: nil, after: b))
                default:
                    break
                }
            }
            return changes
        }.value
    }

    // Per-payload keys that change every build — never meaningful policy.
    private static let volatile: Set<String> = [
        "PayloadUUID", "PayloadIdentifier", "PayloadVersion", "PayloadType", "PayloadDisplayName",
    ]

    /// Flatten a profile's PayloadContent into leaf paths → scalar values,
    /// recursing through nested dicts and arrays so a change buried inside
    /// (PPPC services, PlatformSSO, managed-prefs, notifications, etc.) is
    /// actually detected — not just top-level key add/remove.
    private static func flatten(_ dict: [String: Any]?) -> [String: String] {
        guard let content = dict?["PayloadContent"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for payload in content {
            let type = (payload["PayloadType"] as? String) ?? "Payload"
            let label = (payload["PayloadDisplayName"] as? String) ?? type
            for (k, v) in payload where !volatile.contains(k) {
                flattenValue(v, path: "\(label) → \(k)", into: &out)
            }
        }
        return out
    }

    private static func flattenValue(_ v: Any, path: String, into out: inout [String: String]) {
        if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() {
            out[path] = (v as? Bool) == true ? "true" : "false"
            return
        }
        switch v {
        case let s as String: out[path] = s
        case let n as NSNumber: out[path] = n.stringValue
        case let d as [String: Any]:
            if d.isEmpty { out[path] = "{}" }
            for (k, sub) in d where !volatile.contains(k) { flattenValue(sub, path: "\(path).\(k)", into: &out) }
        case let a as [Any]:
            if a.isEmpty { out[path] = "[]" }
            for (i, sub) in a.enumerated() { flattenValue(sub, path: "\(path)[\(i)]", into: &out) }
        case let data as Data:
            out[path] = "<\(data.count) bytes>"
        default:
            out[path] = String(describing: v)
        }
    }
}
