import Testing
@testable import BlueConnectAdmin

struct DeviceArrowKeysTests {
    private func next(_ ids: [Int], _ current: Int?, down: Bool) -> Int? {
        DeviceArrowKeys<Int>.next(in: ids, from: current, down: down)
    }

    @Test func stepsAndStopsAtTheEnds() {
        #expect(next([1, 2, 3], 2, down: true) == 3)
        #expect(next([1, 2, 3], 2, down: false) == 1)
        #expect(next([1, 2, 3], 3, down: true) == 3)
        #expect(next([1, 2, 3], 1, down: false) == 1)
    }

    @Test func nothingSelectedOrFilteredOut() {
        #expect(next([1, 2, 3], nil, down: true) == 1)
        #expect(next([1, 2, 3], nil, down: false) == 3)
        #expect(next([1, 2, 3], 9, down: true) == 1)
        #expect(next([], 1, down: true) == nil)
    }
}
