import Foundation
import Observation

/// Durable metadata only: command payloads and recovery keys are never logged.
@MainActor
@Observable
final class MDMCommandStore {
    static let shared = MDMCommandStore()
    enum State: String, Codable {
        case queued = "Waiting for device"
        case deferred = "Deferred by device"
        case acknowledged = "Acknowledged"
        case failed = "Failed"
        case unverified = "Individual results unavailable"
        var isPending: Bool { self == .queued || self == .deferred }
    }
    struct Entry: Codable, Identifiable {
        var id: String
        var server: String
        var target: String
        var kind: String
        var createdAt: Date
        var state: State
        var detail: String?
        var checkedAt: Date?
    }
    private(set) var entries: [Entry] = []
    private(set) var refreshing = false
    private(set) var errorText: String?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(fileURL: URL? = URL.applicationSupportDirectory.appendingPathComponent("EdictMDM/command-history.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) { entries = decoded }
    }

    func record(server: String, target: String, plist: Data, failure: String? = nil, note: String? = nil) {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let uuid = object["CommandUUID"] as? String,
              let command = object["Command"] as? [String: Any],
              let kind = command["RequestType"] as? String else { return }
        entries.removeAll { $0.id == uuid && $0.server == server }
        entries.insert(Entry(id: uuid, server: server, target: target, kind: kind, createdAt: Date(),
                             state: failure == nil ? .queued : .failed, detail: failure ?? note), at: 0)
        // Never discard pending work merely because other commands were sent.
        let pending = entries.filter { $0.state.isPending }
        let finished = entries.filter { !$0.state.isPending }.prefix(500)
        entries = (pending + finished).sorted { $0.createdAt > $1.createdAt }
        save()
    }

    func apply(_ result: CommandResult, to id: String, server: String, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.server == server }) else { return }
        entries[index].checkedAt = date
        switch result.status {
        case "Acknowledged":
            let bulk = entries[index].target.contains(",")
            entries[index].state = bulk ? .unverified : .acknowledged
            entries[index].detail = bulk ? "A reply was received; this API cannot attribute all bulk device results." : "The device processed the command. Ongoing policy effects require reported-state verification."
        case "NotNow":
            entries[index].state = .deferred
            entries[index].detail = "The device cannot run this command now. No completion has been confirmed."
        case "Error", "CommandFormatError":
            entries[index].state = .failed
            entries[index].detail = result.failureDescription
        default:
            entries[index].detail = "Received \(result.status); waiting for a terminal device result."
        }
        save()
    }

    func start(settings: SettingsStore) {
        guard polling == nil else { return }
        polling = Task { [weak self, weak settings] in
            while !Task.isCancelled {
                if let self, let settings, settings.mdmEnabled { await self.refresh(settings: settings) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh(settings: SettingsStore,
                 result: ((String) async throws -> CommandResult?)? = nil) async {
        guard !refreshing else { return }
        refreshing = true; errorText = nil
        defer { refreshing = false }
        let api = EnrollmentsAPI(settings: settings)
        let server = settings.nanoMDMBaseURL
        for entry in entries.filter({ $0.server == server && $0.state.isPending }).prefix(100) {
            guard !Task.isCancelled else { return }
            do {
                let response: CommandResult?
                if let result { response = try await result(entry.id) } else { response = try await api.commandResult(uuid: entry.id) }
                if let response { apply(response, to: entry.id, server: server) }
            } catch { errorText = "Couldn't read command results: \(error.localizedDescription)"; break }
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch { errorText = "Couldn't save command history: \(error.localizedDescription)" }
    }
}
