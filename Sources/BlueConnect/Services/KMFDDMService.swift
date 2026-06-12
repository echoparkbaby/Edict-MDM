import Foundation

/// Client for a KMFDDM admin API over the tailnet
/// (e.g. `http://192.0.2.10:9093`). HTTP Basic auth, username `kmfddm`,
/// API key as password. Paths verified against kmfddm v0.7.0's `tools/`
/// scripts. KMFDDM stores declarations, groups them into "sets", and
/// associates enrollments with sets; on any association/content change it
/// tells NanoMDM to send a `DeclarativeManagement` command.
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
