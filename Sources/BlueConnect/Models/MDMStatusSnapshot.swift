import Foundation

/// Reading the server is distinct from when a device reported a value.
struct MDMStatusSnapshot: Codable, Equatable {
    var os: String?
    var fileVault: Bool?
    var model: String?
    var updateState: String?
    var pendingOS: String?
    var updateFailure: String?
    var checkedAt: Date = Date()
    var reportedAt: Date?

    var hasData: Bool {
        os != nil || fileVault != nil || model != nil || updateState != nil
            || pendingOS != nil || updateFailure != nil
    }

    /// Incremental reports must not erase previously known values.
    func merging(_ next: Self) -> Self {
        guard next.hasData else { return self }
        var value = next
        value.os = next.os ?? os
        value.fileVault = next.fileVault ?? fileVault
        value.model = next.model ?? model
        value.updateState = next.updateState ?? updateState
        if next.updateState == nil {
            value.pendingOS = next.pendingOS ?? pendingOS
            value.updateFailure = next.updateFailure ?? updateFailure
        }
        value.reportedAt = next.reportedAt ?? reportedAt
        return value
    }
}
