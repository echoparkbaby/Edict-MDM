import Foundation

/// Client for a KMFDDM admin API over the tailnet
/// (e.g. `http://192.0.2.10:9093`). HTTP Basic auth, username `kmfddm`,
/// API key as password. Paths verified against kmfddm v0.7.0's `tools/`
/// scripts. KMFDDM stores declarations, groups them into "sets", and
/// associates enrollments with sets; on any association/content change it
/// tells NanoMDM to send a `DeclarativeManagement` command.
/// One reported status value from a device, via KMFDDM's status store.
/// `value` is lenient — devices report strings, booleans, and numbers.
struct DDMStatusValue: Decodable, Hashable {
    let path: String
    let value: String
    let timestamp: String?

    enum CodingKeys: String, CodingKey { case path, value, timestamp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        timestamp = try? c.decode(String.self, forKey: .timestamp)
        if let s = try? c.decode(String.self, forKey: .value) {
            value = s
        } else if let b = try? c.decode(Bool.self, forKey: .value) {
            value = b ? "true" : "false"
        } else if let n = try? c.decode(Double.self, forKey: .value) {
            value = n == n.rounded() ? String(Int(n)) : String(n)
        } else {
            value = ""
        }
    }
}

/// One declaration-apply error a device reported, from KMFDDM's status-errors
/// log. The exact JSON shape isn't pinned by Apple's schema, so this decodes
/// leniently: `path` + `timestamp` plus the first human-ish detail field found
/// (`error` / `reason` / `description` / `value`). Empty detail degrades to a
/// path/time entry rather than failing.
struct DDMStatusError: Decodable, Hashable {
    let path: String
    let detail: String
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case path, timestamp, error, reason, description, value, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? "—"
        timestamp = try? c.decode(String.self, forKey: .timestamp)
        var found = ""
        for key: CodingKeys in [.error, .reason, .description, .message, .value] {
            if let s = try? c.decode(String.self, forKey: key), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                found = s
                break
            }
        }
        detail = found
    }
}

struct KMFDDMService {
    let baseURL: String
    let apiKey: String
    private let user = "kmfddm"

    @MainActor
    init(settings: SettingsStore) {
        self.baseURL = settings.kmfddmBaseURL
        self.apiKey = settings.kmfddmAPIKey
    }

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// `GET /version` — health check.
    func version() async throws -> String {
        let (data, _) = try await request("version", authenticated: false)
        struct V: Decodable { let version: String }
        if let v = try? JSONDecoder().decode(V.self, from: data) { return v.version }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// `GET /v1/declarations` → declaration identifiers. Empty store
    /// returns `null`, which decodes to an empty list.
    func listDeclarations() async throws -> [String] {
        let (data, _) = try await request("v1/declarations")
        if let ids = try? JSONDecoder().decode([String].self, from: data) { return ids }
        return []   // body was `null` / empty
    }

    /// `GET /v1/declarations/<id>` → the declaration JSON (raw).
    func declaration(id: String) async throws -> Data {
        let (data, _) = try await request("v1/declarations/\(pathEsc(id))")
        return data
    }

    /// `PUT /v1/declarations` — upsert a declaration (JSON body). 204 on success.
    func putDeclaration(_ json: Data) async throws {
        _ = try await request("v1/declarations", method: "PUT", body: json)
    }

    /// `POST /v1/declarations/<id>/touch` — bump the ServerToken to force
    /// enrolled devices to re-evaluate without changing content.
    func touchDeclaration(id: String) async throws {
        _ = try await request("v1/declarations/\(pathEsc(id))/touch", method: "POST")
    }

    /// `DELETE /v1/declarations/<id>` — remove a declaration.
    func deleteDeclaration(id: String) async throws {
        _ = try await request("v1/declarations/\(pathEsc(id))", method: "DELETE")
    }

    /// `GET /v1/declaration-sets/<id>` → names of the sets containing this
    /// declaration. Empty/`null` body → no sets.
    func setsForDeclaration(id: String) async throws -> [String] {
        let (data, _) = try await request("v1/declaration-sets/\(pathEsc(id))")
        if let sets = try? JSONDecoder().decode([String].self, from: data) { return sets }
        return []
    }

    /// `DELETE /v1/set-declarations/<set>?declaration=<id>` — pull a
    /// declaration out of a set (notifies affected enrollments).
    func removeDeclaration(_ declaration: String, fromSet set: String) async throws {
        _ = try await request("v1/set-declarations/\(pathEsc(set))",
                              method: "DELETE",
                              query: [URLQueryItem(name: "declaration", value: declaration)])
    }

    /// `PUT /v1/set-declarations/<set>?declaration=<id>` — add a declaration
    /// to a set.
    func addDeclaration(_ declaration: String, toSet set: String) async throws {
        _ = try await request("v1/set-declarations/\(pathEsc(set))",
                              method: "PUT",
                              query: [URLQueryItem(name: "declaration", value: declaration)])
    }

    /// `PUT /v1/enrollment-sets/<enrollmentID>?set=<set>` — associate an
    /// enrollment with a set (triggers the DeclarativeManagement push).
    /// KMFDDM returns 304 when the association is already present (no re-notify);
    /// that's success, not an error, so re-assigning is safe + idempotent.
    func assign(enrollmentID: String, toSet set: String) async throws {
        // 304 (already associated) is treated as success by request().
        _ = try await request("v1/enrollment-sets/\(pathEsc(enrollmentID))",
                              method: "PUT",
                              query: [URLQueryItem(name: "set", value: set)])
    }

    /// `GET /v1/status-values/<enrollmentID>[?path=prefix]` — the status
    /// values the device has reported (OS version, FileVault state, …).
    /// Devices only report what a status-subscriptions declaration asks
    /// for; without one, this is empty or just client capabilities.
    func statusValues(enrollmentID: String, pathPrefix: String? = nil) async throws -> [DDMStatusValue] {
        var query: [URLQueryItem] = []
        if let p = pathPrefix { query.append(URLQueryItem(name: "path", value: p)) }
        let (data, _) = try await request("v1/status-values/\(pathEsc(enrollmentID))",
                                          query: query)
        // Shape: {"<enrollment-id>": [{path, value, timestamp, status_id}]}
        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return [] }
        let decoded = try JSONDecoder().decode([String: [DDMStatusValue]].self, from: data)
        return decoded.values.first ?? []
    }

    /// `GET /v1/status-errors/<enrollmentID>` — errors the device reported
    /// applying declarations (a declaration that failed to install, etc.).
    /// NOTE: KMFDDM keeps this as a HISTORICAL log — it does not purge when a
    /// later clean report supersedes it, so treat entries as history (newest
    /// first), not necessarily live state.
    func statusErrors(enrollmentID: String) async throws -> [DDMStatusError] {
        let (data, _) = try await request("v1/status-errors/\(pathEsc(enrollmentID))")
        guard let decoded = try? JSONDecoder().decode([String: [DDMStatusError]].self, from: data)
        else { return [] }
        let list = decoded.values.first ?? []
        return list.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") }
    }

    /// The facts the device list, dashboard, and smart groups all need —
    /// read in ONE status query and picked by exact leaf path. A device
    /// that's only sent client-capabilities reports path strings as
    /// "values" (e.g. `device.operating-system.family`); those are
    /// rejected here so callers see nil ("not reported"), never a path
    /// masquerading as an OS version or model.
    func deviceFacts(enrollmentID: String) async -> (os: String?, fileVault: Bool?, model: String?) {
        let s = await fullStatus(enrollmentID: enrollmentID)
        return (os: s.os, fileVault: s.fileVault, model: s.model)
    }

    /// Software-update posture from the DDM status channel: the device reports
    /// these once subscribed (see `DDMDeclarations.defaultStatusItems`) and/or
    /// when a software-update enforcement declaration is active. Surfacing the
    /// failure reason is the underused-status-channel win (Mac Admins #416).
    struct DDMSoftwareUpdate: Equatable {
        var installState: String?
        var pendingOS: String?
        var failureReason: String?
        var hasData: Bool { installState != nil || pendingOS != nil || failureReason != nil }
    }

    /// OS / FileVault / model / software-update — all from ONE status query, so
    /// the dashboard refresh doesn't pay two round-trips per device.
    func fullStatus(enrollmentID: String) async
        -> (os: String?, fileVault: Bool?, model: String?, su: DDMSoftwareUpdate) {
        let s = (try? await checkedStatus(enrollmentID: enrollmentID)) ?? MDMStatusSnapshot()
        return (s.os, s.fileVault, s.model,
                DDMSoftwareUpdate(installState: s.updateState, pendingOS: s.pendingOS, failureReason: s.updateFailure))
    }

    /// Preserve transport failures instead of turning them into empty reports.
    /// Servers without raw-report support still work through status-values.
    func checkedStatus(enrollmentID: String) async throws -> MDMStatusSnapshot {
        var items: [DDMStatusValue] = []
        var report: [String: Any]?
        var valuesError: Error?
        do { items = try await statusValues(enrollmentID: enrollmentID, pathPrefix: ".StatusItems") }
        catch { valuesError = error }
        do {
            let (data, _) = try await request("v1/status-report/\(pathEsc(enrollmentID))",
                                               query: [URLQueryItem(name: "index", value: "0")])
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is NSNull || object is [String: Any] else {
                throw MDMError.transport("Unexpected DDM status report")
            }
            report = object as? [String: Any]
        } catch {
            if let valuesError { throw valuesError }
        }
        return Self.snapshot(report: report, items: items)
    }

    static func snapshot(report: [String: Any]?, items: [DDMStatusValue], now: Date = Date()) -> MDMStatusSnapshot {
        func leaf(_ suffix: String) -> String? {
            let raw = reportValue(report, path: "StatusItems." + suffix)
                ?? items.filter { $0.path.hasSuffix(suffix) }
                    .max { ($0.timestamp ?? "") < ($1.timestamp ?? "") }?.value
            guard let raw else { return nil }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, ![".", "device.", "softwareupdate.", "management.", "StatusItems"].contains(where: v.hasPrefix)
            else { return nil }
            return v
        }
        let fv = leaf("diskmanagement.filevault.enabled")
        let bool: Bool? = ["true": true, "1": true, "false": false, "0": false][fv ?? ""]
        let dates = items.compactMap { $0.timestamp }.compactMap { ISO8601DateFormatter().date(from: $0) }
        return MDMStatusSnapshot(os: leaf("device.operating-system.version"), fileVault: bool,
                                 model: leaf("device.model.marketing-name") ?? leaf("device.model.identifier"),
                                 updateState: leaf("softwareupdate.install-state"),
                                 pendingOS: leaf("softwareupdate.pending-version.os-version"),
                                 updateFailure: leaf("softwareupdate.failure-reason"), checkedAt: now,
                                 reportedAt: dates.min())
    }

    /// recent raw DDM status report. nil on any failure.
    func latestStatusReport(enrollmentID: String) async -> [String: Any]? {
        guard let (data, _) = try? await request("v1/status-report/\(pathEsc(enrollmentID))",
                                                 query: [URLQueryItem(name: "index", value: "0")])
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Walk a dotted path (`StatusItems.device.model.identifier`) in a raw
    /// report. Scalars only: an object/array leaf (e.g. an empty
    /// `failure-reason: {}`) reads as nil.
    static func reportValue(_ report: [String: Any]?, path: String) -> String? {
        var node: Any? = report
        for key in path.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
        switch node {
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return nil
        }
    }

    // MARK: - HTTP

    private func pathEsc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    @discardableResult
    private func request(_ path: String,
                         method: String = "GET",
                         query: [URLQueryItem] = [],
                         body: Data? = nil,
                         authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, (authenticated == false || !apiKey.isEmpty) else {
            throw MDMError.notConfigured
        }
        let joined = base.hasSuffix("/") ? base + path : base + "/" + path
        guard var comps = URLComponents(string: joined) else { throw MDMError.badURL(joined) }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw MDMError.badURL(joined) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            let token = Data("\(user):\(apiKey)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw MDMError.transport("Non-HTTP response")
            }
            // 304 Not Modified = the resource is already in the requested
            // state (declaration content unchanged, already a set member,
            // already associated). KMFDDM's mutations are idempotent and this
            // client never sends conditional GETs, so 304 is success, not an
            // error — otherwise re-running "Enable reporting" surfaces "HTTP
            // 304" once the declarations already exist.
            guard (200...299).contains(http.statusCode) || http.statusCode == 304 else {
                throw MDMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return (data, http)
        } catch let e as MDMError {
            throw e
        } catch {
            throw MDMError.transport(error.localizedDescription)
        }
    }
}
