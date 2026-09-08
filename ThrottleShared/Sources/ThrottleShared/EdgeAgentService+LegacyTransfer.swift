import Foundation

extension EdgeAgentService {

    /// Context transfer: stream a FULL local session JSONL to the agent, which places
    /// it at `~/.claude/projects/<encoded remoteCwd>/<sessionId>.jsonl` so a follow-up
    /// `start(resume: sessionId)` resumes with the Mac session's context instead of
    /// rebuilding it (verified live 2026-07-12: `claude --resume` accepts a transcript
    /// copied from another machine/cwd). Never truncate the file — a partial JSONL
    /// corrupts the session chain.
    @discardableResult
    /// `runtime` decides where the box files the transcript. Codex stores rollouts
    /// by DATE with the timestamp baked into the filename, so its original name has
    /// to travel too — reconstructing one would put the file somewhere
    /// `codex resume` never looks.
    public static func uploadTranscript(baseURL: String, token: String, remoteCwd: String,
                                        sessionId: String, fileURL: URL,
                                        runtime: String? = nil,
                                        timeout: TimeInterval = 120) async throws -> Int {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/transcripts"
        var items = [URLQueryItem(name: "cwd", value: remoteCwd),
                     URLQueryItem(name: "session", value: sessionId)]
        if let runtime {
            items.append(URLQueryItem(name: "runtime", value: runtime))
            if runtime == "codex" {
                items.append(URLQueryItem(name: "file", value: fileURL.lastPathComponent))
            }
        }
        comps?.queryItems = items
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bytes = obj["bytes"] as? Int else { throw APIError.decode }
        return bytes
    }

    /// Repo transfer: upload a `git bundle` for the agent to clone at `remoteCwd`
    /// (409 = cwd already has content; caller treats that as non-fatal).
    @discardableResult
    /// Pull the box's repository back as a git bundle.
    ///
    /// Returns the bundle on disk and, when the box had uncommitted work, the
    /// commit that captured it. The caller fetches from the bundle into refs of
    /// its own choosing — this deliberately does not decide where the commits
    /// land, because that decision can destroy work and does not belong to a
    /// transport function.
    public static func downloadRepoBundle(baseURL: String, token: String, remoteCwd: String,
                                          timeout: TimeInterval = 300)
        async throws -> (fileURL: URL, wipCommit: String?) {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/repos"
        comps?.queryItems = [URLQueryItem(name: "cwd", value: remoteCwd)]
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "GET"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temp, resp) = try await URLSession.shared.download(for: r)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-edge-\(UUID().uuidString).bundle")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        let wip = http.value(forHTTPHeaderField: "x-throttle-wip")
        return (dest, (wip?.isEmpty == false) ? wip : nil)
    }

    public static func uploadRepoBundle(baseURL: String, token: String, remoteCwd: String,
                                        branch: String, fileURL: URL,
                                        timeout: TimeInterval = 300) async throws -> Bool {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/repos"
        comps?.queryItems = [URLQueryItem(name: "cwd", value: remoteCwd),
                             URLQueryItem(name: "branch", value: branch)]
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: r, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        if http.statusCode == 409 { return false }   // cwd not empty — repo already there
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return true
    }

    /// Bring-back: download the NEWEST transcript for remote session `id` (the box
    /// writes a fresh jsonl per resume, so the current one — not the originally
    /// uploaded id — is returned). Returns (sessionId, jsonl bytes).
    public static func downloadTranscript(baseURL: String, token: String, id: String,
                                          timeout: TimeInterval = 120) async throws -> (sessionId: String, data: Data) {
        let (data, http) = try await request(baseURL, "sessions/\(id)/transcript",
                                             method: "GET", token: token, timeout: timeout)
        guard let sid = http.value(forHTTPHeaderField: "X-Session-Id"), !sid.isEmpty else {
            throw APIError.decode
        }
        return (sid, data)
    }
}
