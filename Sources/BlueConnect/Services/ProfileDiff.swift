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
        let plistData: Data
        if data.first == 0x30 {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("edict-diff-\(UUID().uuidString).mobileconfig")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? data.write(to: tmp)) != nil else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["cms", "-D", "-i", tmp.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            plistData = out.fileHandleForReading.readDataToEndOfFile()
        } else {
            plistData = data
        }
        return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    }

    /// The diff between an already-deployed profile and a new one.
    static func compare(old: Data, new: Data) -> [Change] {
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
    }

    // Per-payload keys that change every build — never meaningful policy.
    private static let volatile: Set<String> = [
        "PayloadUUID", "PayloadIdentifier", "PayloadVersion", "PayloadType", "PayloadDisplayName",
    ]

    /// Flatten a profile's PayloadContent into ["Display → key": "value"].
    private static func flatten(_ dict: [String: Any]?) -> [String: String] {
        guard let content = dict?["PayloadContent"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for payload in content {
            let type = (payload["PayloadType"] as? String) ?? "Payload"
            let label = (payload["PayloadDisplayName"] as? String) ?? type
            for (k, v) in payload where !volatile.contains(k) {
                out["\(label) → \(k)"] = describe(v)
            }
        }
        return out
    }

    private static func describe(_ v: Any) -> String {
        if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() {
            return (v as? Bool) == true ? "true" : "false"
        }
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return "[" + a.map { describe($0) }.joined(separator: ", ") + "]"
        case let d as [String: Any]: return "{" + d.keys.sorted().joined(separator: ", ") + "}"
        default: return String(describing: v)
        }
    }
}
