import Testing
import Foundation
@testable import BlueConnectAdmin

/// The NanoDEP / Apple DEP response decoders — that the snake_case Apple
/// fields map onto the Swift models. Pure JSON decoding, no network.
@Suite("DEP decoding")
struct DEPDecodingTests {

    @Test func decodesDeviceList() throws {
        let json = """
        {"devices":[
          {"serial_number":"C02XYZ123","model":"MacBook Pro","description":"MBP",
           "os":"OSX","device_family":"Mac","profile_status":"pushed",
           "profile_uuid":"ABCD-1234","color":"SPACE GRAY","asset_tag":"A1"}],
         "cursor":"MTIz","more_to_follow":true,"fetched_until":"2026-06-23T00:00:00Z"}
        """
        let list = try JSONDecoder().decode(DEPDeviceList.self, from: Data(json.utf8))
        #expect(list.cursor == "MTIz")
        #expect(list.moreToFollow == true)
        let d = try #require(list.devices.first)
        #expect(d.serialNumber == "C02XYZ123")
        #expect(d.id == "C02XYZ123")          // Identifiable by serial
        #expect(d.model == "MacBook Pro")
        #expect(d.deviceFamily == "Mac")
        #expect(d.profileStatus == "pushed")
        #expect(d.profileUUID == "ABCD-1234")
        #expect(d.assetTag == "A1")
    }

    @Test func decodesAccount() throws {
        let json = """
        {"server_name":"Edict","server_uuid":"U1","admin_id":"admin@x.com",
         "org_name":"McMurtrie","org_email":"a@b.com","org_phone":"555"}
        """
        let a = try JSONDecoder().decode(DEPAccount.self, from: Data(json.utf8))
        #expect(a.serverName == "Edict")
        #expect(a.adminID == "admin@x.com")
        #expect(a.orgName == "McMurtrie")
    }

    @Test func tolerantOfMissingOptionalFields() throws {
        // A sparse device row (only the required serial) still decodes.
        let d = try JSONDecoder().decode(DEPDevice.self, from: Data(#"{"serial_number":"X1"}"#.utf8))
        #expect(d.serialNumber == "X1")
        #expect(d.model == nil)
        #expect(d.profileStatus == nil)
    }
}
