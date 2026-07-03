import Testing
@testable import BlueConnectAdmin

/// `InventoryRowSort` backs every sortable dashboard inventory table. The
/// descending path is the dangerous one: expressing it as `!ascending`
/// makes `sorted(by:)` trap ("Comparison violates its contract!") the
/// moment two cells tie, because the negation returns `true` both ways.
/// These pin numeric-vs-text ordering AND that ties never trap.
@Suite("InventoryRowSort")
struct InventoryRowSortTests {
    typealias Row = InventoryRowSort.Row

    private func rows(_ cells: [String]) -> [Row] {
        cells.enumerated().map { (id: "r\($0.offset)", cells: [$0.element]) }
    }

    @Test func numericColumnSortsByValueNotLexically() {
        let input = rows(["9", "10", "2", "45.2 GB", "8 of 30"])
        let asc = InventoryRowSort.sorted(input, column: 0, ascending: true).map { $0.cells[0] }
        #expect(asc == ["2", "8 of 30", "9", "10", "45.2 GB"])
        let desc = InventoryRowSort.sorted(input, column: 0, ascending: false).map { $0.cells[0] }
        #expect(desc == ["45.2 GB", "10", "9", "8 of 30", "2"])
    }

    @Test func textColumnIsCaseInsensitive() {
        let input = rows(["banana", "Apple", "cherry"])
        let asc = InventoryRowSort.sorted(input, column: 0, ascending: true).map { $0.cells[0] }
        #expect(asc == ["Apple", "banana", "cherry"])
    }

    /// The regression guard: many equal cells in descending order must not
    /// trap. With the old `!ascending` comparator this crashes once the
    /// collection is large enough for introsort to bounds-check.
    @Test func manyTiesDescendingDoesNotTrap() {
        let input = rows(Array(repeating: "Verified", count: 64))
        let desc = InventoryRowSort.sorted(input, column: 0, ascending: false)
        #expect(desc.count == 64)
        #expect(desc.allSatisfy { $0.cells[0] == "Verified" })
    }

    @Test func mixedNumberAndTextTiesAreStableEnoughToNotTrap() {
        // Equal numeric prefixes fall through to text compare; equal text
        // ties must resolve to "not less than" both ways.
        let input = rows(["5 apples", "5 apples", "5 apples", "3 pears", "3 pears"])
        let desc = InventoryRowSort.sorted(input, column: 0, ascending: false).map { $0.cells[0] }
        #expect(desc == ["5 apples", "5 apples", "5 apples", "3 pears", "3 pears"])
    }

    @Test func nilColumnPreservesIncomingOrder() {
        let input = rows(["c", "a", "b"])
        let out = InventoryRowSort.sorted(input, column: nil, ascending: true).map { $0.cells[0] }
        #expect(out == ["c", "a", "b"])
    }

    @Test func outOfRangeColumnTreatsCellsAsEmptyAndDoesNotTrap() {
        let input = rows(["a", "b", "c"])   // only column 0 exists
        let out = InventoryRowSort.sorted(input, column: 5, ascending: false)
        #expect(out.count == 3)
    }
}
