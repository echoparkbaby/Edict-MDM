import Foundation

/// A saved configuration profile — either built from a template and kept,
/// or imported from a .mobileconfig file (signed or plain). The raw bytes
/// are stored verbatim so signed profiles deploy with their signature
/// intact. Persisted by SavedProfilesStore.
struct SavedProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Base64 of the .mobileconfig bytes (signed or plain).
    var dataBase64: String
    var favorite: Bool = false
    /// Short payload-type summary for the list, e.g. "TCC, Notifications".
    var summary: String = ""

    var data: Data { Data(base64Encoded: dataBase64) ?? Data() }
    /// Signed profiles start with the DER/PKCS7 sequence byte 0x30.
    var isSigned: Bool { data.first == 0x30 }

    init(id: UUID = UUID(), name: String, data: Data, favorite: Bool = false, summary: String = "") {
        self.id = id
        self.name = name
        self.dataBase64 = data.base64EncodedString()
        self.favorite = favorite
        self.summary = summary
    }
}
