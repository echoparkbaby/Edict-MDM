import SwiftUI

/// Up/Down arrow keys move the selection through a hand-built device list
/// (the dashboard tables are LazyVStacks, not `Table`, so they get no
/// keyboard navigation for free). The list takes keyboard focus when it is
/// clicked — not whenever the selection changes, which would pull focus out
/// of the search box as filtering changes which row counts as selected.
// ponytail: no scroll-into-view — fleets here fit on screen; wrap the rows in
// a ScrollViewReader and scrollTo(next) if a list ever outgrows the window.
struct DeviceArrowKeys<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let selected: ID?
    let select: (ID) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(!ids.isEmpty)
            .focusEffectDisabled()
            .focused($focused)
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard let next = Self.next(in: ids, from: selected, down: press.key == .downArrow) else { return .ignored }
                select(next)
                return .handled
            }
    }

    /// The row to move to: one step from the current row, staying put at
    /// either end; with nothing selected, Down picks the first row and Up
    /// the last. nil only for an empty list.
    static func next(in ids: [ID], from current: ID?, down: Bool) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return down ? ids.first : ids.last }
        return ids[min(max(i + (down ? 1 : -1), 0), ids.count - 1)]
    }
}

extension View {
    func deviceArrowKeys<ID: Hashable>(_ ids: [ID], selected: ID?, select: @escaping (ID) -> Void) -> some View {
        modifier(DeviceArrowKeys(ids: ids, selected: selected, select: select))
    }
}
