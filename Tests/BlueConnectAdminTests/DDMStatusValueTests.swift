import Testing
import Foundation
@testable import BlueConnectAdmin

/// KMFDDM reports status values as strings, booleans, or numbers; the
/// `DDMStatusValue` decoder coerces them all to a string so the device
/// dashboard reads one type. Pure Decodable logic.
@Suite("DDM status value decoding")
struct DDMStatusValueTests {

    private func decode(_ json: String) throws -> DDMStatusValue {
        try JSONDecoder().decode(DDMStatusValue.self, from: Data(json.utf8))
    }

    @Test func stringValuePassesThrough() throws {
        let v = try decode(#"{"path":".os","value":"macOS"}"#)
        #expect(v.path == ".os")
        #expect(v.value == "macOS")
        #expect(v.timestamp == nil)
    }

    @Test func boolValueBecomesTrueFalse() throws {
        #expect(try decode(#"{"path":".fv","value":true}"#).value == "true")
        #expect(try decode(#"{"path":".fv","value":false}"#).value == "false")
    }

    @Test func numericValueRendersWithoutTrailingZero() throws {
        #expect(try decode(#"{"path":".n","value":15}"#).value == "15")
        #expect(try decode(#"{"path":".n","value":15.5}"#).value == "15.5")
    }

    @Test func missingValueIsEmptyString() throws {
        #expect(try decode(#"{"path":".x"}"#).value == "")
    }

    @Test func timestampDecodedWhenPresent() throws {
        let v = try decode(#"{"path":".x","value":"y","timestamp":"2026-01-01T00:00:00Z"}"#)
        #expect(v.timestamp == "2026-01-01T00:00:00Z")
    }
}
