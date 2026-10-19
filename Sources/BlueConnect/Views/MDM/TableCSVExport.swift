import AppKit
import UniformTypeIdentifiers

/// Shared "Save table as CSV" helper used by the dashboard's device table
/// and the MunkiReport-backed category tables. Quotes fields that need it
/// and writes UTF-8 to wherever the operator points the save panel.
/// (Distinct from `HostsCSVBuilder`, which builds the fixed-schema hosts
/// export as a `FileDocument`.)
enum TableCSVExport {
    static func escape(_ s: String) -> String {
        (s.contains(",") || s.contains("\"") || s.contains("\n"))
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : s
    }

    /// Throws if the write fails; cancelling the panel is not an error.
    static func save(filename: String, columns: [String], rows: [[String]]) throws {
        var csv = columns.map(escape).joined(separator: ",") + "\n"
        for r in rows { csv += r.map(escape).joined(separator: ",") + "\n" }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try Data(csv.utf8).write(to: url)
        }
    }
}
