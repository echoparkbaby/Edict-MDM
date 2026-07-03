import Foundation

/// Sorting for the dashboard inventory tables. Extracted from
/// `GroupDashboardView.sortedRows` so the comparator is unit-testable: a
/// descending sort must not be expressed as the *negation* of an ascending
/// comparison, because negating a non-strict "a < b" yields `true` for both
/// `(a,b)` and `(b,a)` on tied cells — a strict-weak-ordering violation that
/// makes `sorted(by:)` trap ("Comparison violates its contract!").
enum InventoryRowSort {
    typealias Row = (id: String, cells: [String])

    /// The leading numeric prefix of a cell ("12 of 30" → 12, "45.2 GB" →
    /// 45.2, "-3 °C" → -3), or nil when the cell doesn't start with a number.
    static func leadingNumber(_ s: String) -> Double? {
        var n = ""
        for ch in s.trimmingCharacters(in: .whitespaces) {
            if ch.isNumber || ch == "." { n.append(ch) }
            else if n.isEmpty && ch == "-" { n.append(ch) }
            else { break }
        }
        return n.isEmpty ? nil : Double(n)
    }

    /// Numeric-aware, case-insensitive sort by `column`. A nil column leaves
    /// rows in their incoming order.
    static func sorted(_ rows: [Row], column: Int?, ascending: Bool) -> [Row] {
        guard let col = column else { return rows }
        func cell(_ r: Row) -> String { col < r.cells.count ? r.cells[col] : "" }
        func less(_ x: Row, _ y: Row) -> Bool {
            let kx = cell(x), ky = cell(y)
            if let nx = leadingNumber(kx), let ny = leadingNumber(ky), nx != ny {
                return nx < ny
            }
            return kx.localizedCaseInsensitiveCompare(ky) == .orderedAscending
        }
        // Swap operands for descending — never negate `less`.
        return rows.sorted { a, b in ascending ? less(a, b) : less(b, a) }
    }
}
