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
    func assign(enrollmentID: String, toSet set: String) async throws {
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
        guard let decoded = try? JSONDecoder().decode([String: [DDMStatusValue]].self, from: data)
        else { return [] }
        return decoded.values.first ?? []
    }

    /// The facts the device list, dashboard, and smart groups all need —
    /// read in ONE status query and picked by exact leaf path. A device
    /// that's only sent client-capabilities reports path strings as
    /// "values" (e.g. `device.operating-system.family`); those are
    /// rejected here so callers see nil ("not reported"), never a path
    /// masquerading as an OS version or model.
    func deviceFacts(enrollmentID: String) async -> (os: String?, fileVault: Bool?, model: String?) {
        let items = (try? await statusValues(enrollmentID: enrollmentID,
                                             pathPrefix: ".StatusItems")) ?? []
        func leaf(_ suffix: String) -> String? {
            guard let raw = items.first(where: { $0.path.hasSuffix(suffix) })?.value else { return nil }
            let v = raw.trimmingCharacters(in: .whitespaces)
            // Reject capability paths that come back as values.
            if v.isEmpty || v.hasPrefix(".") || v.hasPrefix("device.")
                || v.hasPrefix("management.") || v.hasPrefix("StatusItems") { return nil }
            return v
        }
        let os = leaf("operating-system.version")
        let model = leaf("model.marketing-name") ?? leaf("model.identifier")
        let fv = (items.first { $0.path.hasSuffix("filevault.enabled") })?.value
        let fileVault: Bool? = fv.map { $0 == "true" || $0 == "1" }
        return (os: os, fileVault: fileVault, model: model)
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
            guard (200...299).contains(http.statusCode) else {
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
