import Foundation

struct BridgeConfig: Equatable {
    var baseURL: URL
    var token: String
}

enum BridgeError: LocalizedError {
    case badURL
    case badStatus(Int)
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server address."
        case .badStatus(401): return "Unauthorized — check your pairing token."
        case .badStatus(let code): return "Server returned status \(code)."
        case .serverMessage(let msg): return msg
        }
    }
}

/// Talks to the TethrX bridge daemon. All calls are async; `events(…)`
/// returns a live stream of normalized Server-Sent Events.
struct BridgeClient {
    let config: BridgeConfig
    private var session: URLSession { .shared }

    // MARK: Requests

    private func url(_ path: String) throws -> URL {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.path = path
        guard let u = comps.url else { throw BridgeError.badURL }
        return u
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.timeoutInterval = 15   // bound failed reconnects (streaming sets its own)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BridgeError.badStatus(http.statusCode)
        }
    }

    // MARK: Endpoints

    func health() async throws -> HealthInfo {
        let (data, resp) = try await session.data(for: try request("/api/health"))
        try Self.check(resp)
        return try JSONDecoder().decode(HealthInfo.self, from: data)
    }

    func listSessions() async throws -> [SessionInfo] {
        let (data, resp) = try await session.data(for: try request("/api/sessions"))
        try Self.check(resp)
        struct Wrapper: Codable { let sessions: [SessionInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).sessions
    }

    /// Overall token/cost usage across all sessions (`GET /api/usage`).
    func usage() async throws -> UsageReport {
        let (data, resp) = try await session.data(for: try request("/api/usage"))
        try Self.check(resp)
        return try JSONDecoder().decode(UsageReport.self, from: data)
    }

    /// Sessions from the host Grok CLI store (not yet bridge sessions).
    func listGrokSessions(limit: Int = 50, cwd: String? = nil) async throws -> [GrokCliSession] {
        guard var comps = URLComponents(url: try url("/api/grok-sessions"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cwd, !cwd.isEmpty { items.append(URLQueryItem(name: "cwd", value: cwd)) }
        comps.queryItems = items
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        // Accept either a bare array or `{ "sessions": [...] }`.
        if let list = try? JSONDecoder().decode([GrokCliSession].self, from: data) {
            return list
        }
        struct Wrapper: Codable { let sessions: [GrokCliSession] }
        return try JSONDecoder().decode(Wrapper.self, from: data).sessions
    }

    func createSession(
        cwd: String?,
        effort: String? = nil,
        planMode: Bool = false,
        autoApprove: Bool = false,
        resumeGrokSessionId: String? = nil,
        title: String? = nil,
        sessionKind: String? = nil,
        agentName: String? = nil
    ) async throws -> SessionInfo {
        var body: [String: Any] = [:]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let effort, !effort.isEmpty { body["effort"] = effort }
        if planMode { body["planMode"] = true }
        if autoApprove { body["autoApprove"] = true }
        if let resumeGrokSessionId, !resumeGrokSessionId.isEmpty {
            body["resumeGrokSessionId"] = resumeGrokSessionId
        }
        if let title, !title.isEmpty { body["title"] = title }
        if let sessionKind, !sessionKind.isEmpty { body["sessionKind"] = sessionKind }
        if let agentName, !agentName.isEmpty { body["agentName"] = agentName }
        let (data, resp) = try await session.data(for: try request("/api/sessions", method: "POST", json: body))
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    func deleteSession(_ id: String) async throws {
        let (_, resp) = try await session.data(for: try request("/api/sessions/\(id)", method: "DELETE"))
        try Self.check(resp)
    }

    func renameSession(_ id: String, title: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(id)", method: "PATCH", json: ["title": title]))
        try Self.check(resp)
    }

    /// Set (or clear, with "") a session's folder grouping.
    func setFolder(_ id: String, folder: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(id)", method: "PATCH", json: ["folder": folder]))
        try Self.check(resp)
    }

    /// Register this device's APNs token so the bridge can push alerts.
    func registerDevice(_ token: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/devices", method: "POST", json: ["token": token]))
        try Self.check(resp)
    }

    /// Register ActivityKit push token so the bridge can update Live Activity in background.
    func registerActivityToken(sessionId: String, token: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/activity-token", method: "POST",
                             json: ["token": token]))
        try Self.check(resp)
    }

    /// Probe APNs AuthKey + optional test push (bridge-side dry-run).
    @discardableResult
    func pushProbe(sendTest: Bool = false) async throws -> [String: Any] {
        let (data, resp) = try await session.data(
            for: try request("/api/push/probe", method: "POST",
                             json: ["sendTest": sendTest]))
        try Self.check(resp)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Send a user message. Optional `images` are `[{name, mime, data: base64}]`.
    func send(sessionId: String, text: String, images: [[String: Any]]? = nil) async throws {
        var body: [String: Any] = ["text": text]
        if let images, !images.isEmpty { body["images"] = images }
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/messages", method: "POST", json: body))
        try Self.check(resp)
    }

    /// Load a host file (image) as base64 for the chat viewer.
    func fetchFile(path: String) async throws -> (mime: String, data: Data) {
        guard var comps = URLComponents(url: try url("/api/fs/file"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 30
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct FilePayload: Codable {
            let mime: String?
            let data: String
        }
        let payload = try JSONDecoder().decode(FilePayload.self, from: data)
        guard let raw = Data(base64Encoded: payload.data) else { throw BridgeError.badStatus(500) }
        return (payload.mime ?? "application/octet-stream", raw)
    }

    func cancel(sessionId: String) async {
        _ = try? await session.data(
            for: try request("/api/sessions/\(sessionId)/cancel", method: "POST", json: [:]))
    }

    /// Answer a pending ACP permission request. Pass nil to cancel.
    func resolvePermission(sessionId: String, requestId: String, optionId: String?, always: Bool = false) async throws {
        var body: [String: Any] = optionId.map { ["optionId": $0] } ?? [:]
        if always { body["always"] = true }
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/permissions/\(requestId)", method: "POST", json: body))
        try Self.check(resp)
    }

    /// Live per-session settings (plan mode, reasoning effort, auto-approve).
    @discardableResult
    func setConfig(sessionId: String, planMode: Bool? = nil, effort: String? = nil, autoApprove: Bool? = nil) async throws -> SessionInfo {
        var body: [String: Any] = [:]
        if let planMode { body["planMode"] = planMode }
        if let effort { body["effort"] = effort }
        if let autoApprove { body["autoApprove"] = autoApprove }
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/config", method: "POST", json: body))
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    /// Approve or reject a plan (plan mode). Approving proceeds to execution.
    func resolvePlan(sessionId: String, requestId: String, approved: Bool) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/plan/\(requestId)", method: "POST", json: ["approved": approved]))
        try Self.check(resp)
    }

    // MARK: Compact / search / logs / schedules / project files

    /// Compact a session: summary turn + fresh session with seedContext. Long timeout.
    func compact(sessionId: String) async throws -> SessionInfo {
        var req = try request("/api/sessions/\(sessionId)/compact", method: "POST", json: [:])
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    /// Full-text search across every session's conversation history.
    func search(_ query: String) async throws -> [SearchResult] {
        guard var comps = URLComponents(url: try url("/api/search"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let results: [SearchResult] }
        return try JSONDecoder().decode(Wrapper.self, from: data).results
    }

    /// Bridge console ring buffer.
    func logs() async throws -> [String] {
        let (data, resp) = try await session.data(for: try request("/api/logs"))
        try Self.check(resp)
        struct Wrapper: Codable { let lines: [String] }
        return try JSONDecoder().decode(Wrapper.self, from: data).lines
    }

    func listSchedules() async throws -> [BridgeSchedule] {
        let (data, resp) = try await session.data(for: try request("/api/schedules"))
        try Self.check(resp)
        struct Wrapper: Codable { let schedules: [BridgeSchedule] }
        return try JSONDecoder().decode(Wrapper.self, from: data).schedules
    }

    @discardableResult
    func createSchedule(sessionId: String, prompt: String, hour: Int, minute: Int, weekdays: [Int]) async throws -> BridgeSchedule {
        let (data, resp) = try await session.data(
            for: try request("/api/schedules", method: "POST",
                             json: ["sessionId": sessionId, "prompt": prompt,
                                    "hour": hour, "minute": minute, "weekdays": weekdays]))
        try Self.check(resp)
        return try JSONDecoder().decode(BridgeSchedule.self, from: data)
    }

    func setScheduleEnabled(_ id: String, enabled: Bool) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/schedules/\(id)", method: "PATCH", json: ["enabled": enabled]))
        try Self.check(resp)
    }

    func deleteSchedule(_ id: String) async throws {
        let (_, resp) = try await session.data(for: try request("/api/schedules/\(id)", method: "DELETE"))
        try Self.check(resp)
    }

    /// Working-dir picker — maps jailed `/api/fs` into DirListing shape.
    func listDirs(path: String?) async throws -> DirListing {
        let listing = try await listFs(path: path ?? "")
        let dirs = listing.entries.filter(\.isDir).map { e -> DirListing.Dir in
            let child = listing.path.hasSuffix("/")
                ? listing.path + e.name
                : listing.path + "/" + e.name
            return DirListing.Dir(name: e.name, path: e.path ?? child)
        }
        let parent: String? = {
            let p = listing.path
            if p.isEmpty || p == "/" { return nil }
            let up = (p as NSString).deletingLastPathComponent
            return up.isEmpty ? "/" : up
        }()
        return DirListing(path: listing.path, parent: parent, dirs: dirs)
    }

    /// List one folder of the session's project (path relative to its cwd).
    func listFiles(sessionId: String, path: String) async throws -> [FileEntry] {
        guard var comps = URLComponents(url: try url("/api/sessions/\(sessionId)/files"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let entries: [FileEntry] }
        return try JSONDecoder().decode(Wrapper.self, from: data).entries
    }

    /// Fetch a text file's content from the session's project.
    func fileContent(sessionId: String, path: String) async throws -> FileContent {
        guard var comps = URLComponents(url: try url("/api/sessions/\(sessionId)/file"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(FileContent.self, from: data)
    }

    // MARK: Filesystem browse + cwd recents

    /// List a directory on the host (`GET /api/fs?path=`). Empty path → bridge default cwd.
    func listFs(path: String) async throws -> FsListing {
        guard var comps = URLComponents(url: try url("/api/fs"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        var items: [URLQueryItem] = []
        if !path.isEmpty { items.append(URLQueryItem(name: "path", value: path)) }
        if !items.isEmpty { comps.queryItems = items }
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(FsListing.self, from: data)
    }

    /// Filename search under `cwd` (`GET /api/fs/search?q=&cwd=`). Used for `@path` autocomplete.
    /// Bridge returns `{ results: [{ path, type }] }` — mapped to `FsEntry` with basename as `name`.
    func searchFs(query: String, cwd: String?) async throws -> [FsEntry] {
        guard var comps = URLComponents(url: try url("/api/fs/search"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "q", value: query)]
        if let cwd, !cwd.isEmpty { items.append(URLQueryItem(name: "cwd", value: cwd)) }
        comps.queryItems = items
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)

        struct SearchHit: Codable {
            let path: String
            let type: String
            var size: Int?
        }
        struct ResultsWrapper: Codable { let results: [SearchHit] }
        struct EntriesWrapper: Codable { let entries: [FsEntry] }

        func mapHits(_ hits: [SearchHit]) -> [FsEntry] {
            hits.map { h in
                FsEntry(
                    name: (h.path as NSString).lastPathComponent,
                    type: h.type,
                    size: h.size,
                    path: h.path
                )
            }
        }

        if let w = try? JSONDecoder().decode(ResultsWrapper.self, from: data) {
            return mapHits(w.results)
        }
        if let w = try? JSONDecoder().decode(EntriesWrapper.self, from: data) {
            return w.entries
        }
        if let list = try? JSONDecoder().decode([FsEntry].self, from: data) {
            return list
        }
        if let hits = try? JSONDecoder().decode([SearchHit].self, from: data) {
            return mapHits(hits)
        }
        return []
    }

    /// Recent working directories on this bridge (`GET /api/cwd-recents`).
    func cwdRecents() async throws -> [String] {
        let (data, resp) = try await session.data(for: try request("/api/cwd-recents"))
        try Self.check(resp)
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        struct Wrapper: Codable { let recents: [String] }
        return try JSONDecoder().decode(Wrapper.self, from: data).recents
    }

    /// Push a path to the bridge's MRU cwd list (`POST /api/cwd-recents`).
    func pushCwdRecent(_ path: String) async throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (data, resp) = try await session.data(
            for: try request("/api/cwd-recents", method: "POST", json: ["path": trimmed]))
        try Self.check(resp)
        _ = data
    }

    // MARK: Git review

    func gitStatus(sessionId: String) async throws -> GitStatus {
        let (data, resp) = try await session.data(for: try request("/api/sessions/\(sessionId)/git"))
        try Self.check(resp)
        return try JSONDecoder().decode(GitStatus.self, from: data)
    }

    func gitDiff(sessionId: String, file: String) async throws -> String {
        guard var comps = URLComponents(url: try url("/api/sessions/\(sessionId)/git"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "file", value: file)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let diff: String }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).diff) ?? ""
    }

    @discardableResult
    func gitCommit(sessionId: String, message: String) async throws -> String {
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST",
                             json: ["action": "commit", "message": message]))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        if !r.ok { throw BridgeError.badStatus(500) }
        return r.output ?? ""
    }

    @discardableResult
    func gitDiscard(sessionId: String) async throws -> String {
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST", json: ["action": "discard"]))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        return r.output ?? ""
    }

    /// Push + `gh pr create`. Returns the PR URL when available, else command output.
    @discardableResult
    func gitCreatePR(sessionId: String, title: String?, body: String?) async throws -> String {
        var payload: [String: Any] = ["action": "pr"]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["title"] = title
        }
        if let body { payload["body"] = body }
        var req = try request("/api/sessions/\(sessionId)/git", method: "POST", json: payload)
        req.timeoutInterval = 120   // push + gh can be slow
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Result: Codable {
            let ok: Bool
            let url: String?
            let output: String?
            let error: String?
        }
        let r = try JSONDecoder().decode(Result.self, from: data)
        if !r.ok {
            throw BridgeError.serverMessage(r.error ?? r.output ?? "PR create failed")
        }
        if let url = r.url, !url.isEmpty { return url }
        return r.output ?? ""
    }

    /// Recent GitHub Actions runs for the session cwd (`GET …/ci`).
    func ciRuns(sessionId: String) async throws -> [CiRun] {
        var req = try request("/api/sessions/\(sessionId)/ci")
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let runs: [CiRun]? }
        return (try JSONDecoder().decode(Wrapper.self, from: data).runs) ?? []
    }

    /// Live event stream for a session. Each yielded value is one normalized
    /// event object (e.g. `["kind": "text", "text": "…"]`). The stream ends when
    /// the connection closes; callers typically reconnect.
    func events(sessionId: String, lastEventId: Int = 0) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("/api/sessions/\(sessionId)/stream")
                    req.timeoutInterval = 3600
                    req.setValue(String(lastEventId), forHTTPHeaderField: "Last-Event-ID")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, resp) = try await session.bytes(for: req)
                    try Self.check(resp)

                    // SSE frames are line-delimited: an `id:` line then a `data:` line.
                    // The id has to be surfaced, otherwise a reconnect can't tell the
                    // bridge where it left off and the whole history replays again.
                    var currentId = 0
                    for try await line in bytes.lines {
                        if line.hasPrefix("id:") {
                            currentId = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) ?? currentId
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if currentId > 0 { obj["_eventId"] = currentId }
                        continuation.yield(obj)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
