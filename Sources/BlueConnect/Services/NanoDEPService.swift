import Foundation

/// Client for a NanoDEP server (Apple Automated Device Enrollment / "DEP")
/// over the tailnet, e.g. `http://192.0.2.10:9001`. HTTP Basic auth, username
/// `depserver`, API key as password. NanoDEP proxies Apple's DEP cloud API at
/// `/proxy/<name>/<apple-path>` (→ `https://mdmenrollment.apple.com/<apple-path>`)
/// and keeps admin state under `/v1/` (tokens, assigner, config). `<name>` is
/// NanoDEP's handle for one ABM/ASM MDM-server token.
///
/// NOTE: built against NanoDEP's documented HTTP surface + Apple's DEP web
/// service paths, but NOT verified end-to-end against a live Apple Business
/// Manager token — the UI flags this.
struct NanoDEPService {
    let baseURL: String
    let apiKey: String
    let name: String
    private let user = "depserver"

    @MainActor
    init(settings: SettingsStore) {
        self.baseURL = settings.nanoDEPBaseURL
        self.apiKey = settings.nanoDEPAPIKey
        self.name = settings.nanoDEPName.isEmpty ? "default" : settings.nanoDEPName
    }

    init(baseURL: String, apiKey: String, name: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.name = name
    }

    /// The DEP profile's enrollment URL default — where the device fetches its
    /// enrollment profile during Setup Assistant. For NanoMDM that's the
    /// `/mdm/enroll` endpoint (NOT the `/mdm` check-in path). Pure + testable.
    static func enrollURL(publicBase: String) -> String {
        let b = publicBase.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return "" }
        return (b.hasSuffix("/") ? String(b.dropLast()) : b) + "/mdm/enroll"
    }

    // MARK: - Health

    /// `GET /version`.
    func version() async throws -> String {
        let (data, _) = try await request("version", authenticated: false)
        struct V: Decodable { let version: String }
        if let v = try? JSONDecoder().decode(V.self, from: data) { return v.version }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    // MARK: - Account

    /// `GET /proxy/<name>/account` — the ABM/ASM MDM-server account detail.
    func account() async throws -> DEPAccount {
        let (data, _) = try await request("proxy/\(pathEsc(name))/account")
        return try JSONDecoder().decode(DEPAccount.self, from: data)
    }

    // MARK: - Devices

    /// `POST /proxy/<name>/server/devices` — paginated fetch of the devices
    /// assigned to this MDM server in ABM. Pass the previous page's `cursor`
    /// to continue.
    func fetchDevices(cursor: String? = nil, limit: Int = 100) async throws -> DEPDeviceList {
        var body: [String: Any] = ["limit": limit]
        if let cursor { body["cursor"] = cursor }
        let data = try JSONSerialization.data(withJSONObject: body)
        let (resp, _) = try await request("proxy/\(pathEsc(name))/server/devices", method: "POST", body: data)
        return try JSONDecoder().decode(DEPDeviceList.self, from: resp)
    }

    /// Fetch every page and return the flattened device list.
    func allDevices() async throws -> [DEPDevice] {
        var out: [DEPDevice] = []
        var cursor: String? = nil
        // Bounded so a misbehaving cursor can't loop forever.
        for _ in 0..<200 {
            let page = try await fetchDevices(cursor: cursor)
            out.append(contentsOf: page.devices)
            guard page.moreToFollow == true, let next = page.cursor, !next.isEmpty else { break }
            cursor = next
        }
        return out
    }

    // MARK: - Profiles

    /// `POST /proxy/<name>/profile` — define a DEP enrollment profile (the
    /// thing that makes a device auto-enroll). Returns the new profile UUID.
    /// Empty optionals are omitted.
    func defineProfile(profileName: String, url: String,
                       supervised: Bool, mandatory: Bool, mdmRemovable: Bool,
                       awaitConfigured: Bool, allowPairing: Bool,
                       supportPhone: String?, supportEmail: String?, department: String?,
                       skipSetupItems: [String], assignSerials: [String] = []) async throws -> String {
        var p: [String: Any] = [
            "profile_name": profileName,
            "url": url,
            "allow_pairing": allowPairing,
            "is_supervised": supervised,
            "is_mandatory": mandatory,
            "is_mdm_removable": mdmRemovable,
            "await_device_configured": awaitConfigured,
            "skip_setup_items": skipSetupItems,
        ]
        if let v = supportPhone, !v.isEmpty { p["support_phone_number"] = v }
        if let v = supportEmail, !v.isEmpty { p["support_email_address"] = v }
        if let v = department, !v.isEmpty { p["department"] = v }
        if !assignSerials.isEmpty { p["devices"] = assignSerials }
        let body = try JSONSerialization.data(withJSONObject: p)
        let (data, _) = try await request("proxy/\(pathEsc(name))/profile", method: "POST", body: body)
        struct R: Decodable { let profile_uuid: String }
        return try JSONDecoder().decode(R.self, from: data).profile_uuid
    }

    /// `POST /proxy/<name>/profile/devices` — assign an existing profile to
    /// device serials. Returns serial → status ("SUCCESS", "NOT_ACCESSIBLE", …).
    @discardableResult
    func assignProfile(uuid: String, serials: [String]) async throws -> [String: String] {
        let body = try JSONSerialization.data(withJSONObject: ["profile_uuid": uuid, "devices": serials])
        let (data, _) = try await request("proxy/\(pathEsc(name))/profile/devices", method: "POST", body: body)
        struct R: Decodable { let devices: [String: String] }
        return (try? JSONDecoder().decode(R.self, from: data).devices) ?? [:]
    }

    /// `PUT /v1/assigner/<name>?profile_uuid=<uuid>` — store the auto-assigner
    /// profile UUID so NanoDEP's syncer assigns it to every newly-appearing ABM
    /// device. NanoDEP reads the UUID from the query string, not the body.
    func setAutoAssigner(profileUUID: String) async throws {
        let q = profileUUID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileUUID
        _ = try await request("v1/assigner/\(pathEsc(name))?profile_uuid=\(q)", method: "PUT")
    }

    /// `GET /v1/assigner/<name>` — the current auto-assigner profile UUID, if set.
    func autoAssigner() async throws -> String? {
        let (data, _) = try await request("v1/assigner/\(pathEsc(name))")
        struct R: Decodable { let profile_uuid: String? }
        return try? JSONDecoder().decode(R.self, from: data).profile_uuid
    }

    // MARK: - HTTP

    private func pathEsc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    @discardableResult
    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, (authenticated == false || !apiKey.isEmpty) else { throw MDMError.notConfigured }
        let joined = base.hasSuffix("/") ? base + path : base + "/" + path
        guard let url = URL(string: joined) else { throw MDMError.badURL(joined) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 30   // Apple's DEP cloud can be slow through the proxy.
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            let token = Data("\(user):\(apiKey)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw MDMError.transport("Non-HTTP response") }
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

// MARK: - Models

/// Apple DEP account detail (`GET /account`).
struct DEPAccount: Decodable {
    let serverName: String?
    let serverUUID: String?
    let adminID: String?
    let orgName: String?
    let orgEmail: String?
    let orgPhone: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "server_name"
        case serverUUID = "server_uuid"
        case adminID = "admin_id"
        case orgName = "org_name"
        case orgEmail = "org_email"
        case orgPhone = "org_phone"
    }
}

/// One device assigned to this MDM server in ABM.
struct DEPDevice: Decodable, Identifiable, Hashable {
    let serialNumber: String
    let model: String?
    let description: String?
    let os: String?
    let deviceFamily: String?
    let profileStatus: String?   // "empty" | "assigned" | "pushed" | "removed"
    let profileUUID: String?
    let color: String?
    let assetTag: String?

    var id: String { serialNumber }

    enum CodingKeys: String, CodingKey {
        case serialNumber = "serial_number"
        case model, description, os, color
        case deviceFamily = "device_family"
        case profileStatus = "profile_status"
        case profileUUID = "profile_uuid"
        case assetTag = "asset_tag"
    }
}

/// A page of the DEP device list.
struct DEPDeviceList: Decodable {
    let devices: [DEPDevice]
    let cursor: String?
    let moreToFollow: Bool?
    let fetchedUntil: String?

    enum CodingKeys: String, CodingKey {
        case devices, cursor
        case moreToFollow = "more_to_follow"
        case fetchedUntil = "fetched_until"
    }
}
