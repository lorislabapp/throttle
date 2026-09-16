import Darwin
import Foundation

/// A narrowing grant for one launched runtime, task and mission.
///
/// Stdio still inherits the user's operating-system rights. This descriptor
/// therefore cannot be an OS sandbox; it makes Throttle's own MCP surface
/// fail closed outside one explicit capability and leaves a durable revocation
/// fact. The descriptor is re-read on every call so expiry and revocation take
/// effect without trusting a long-lived in-memory copy.
struct PlanMCPAuthority: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable, CaseIterable { case read, claim, event, verdict }

    enum Failure: Error, Equatable, Sendable {
        case unreadable(String)
        case unsafe(String)
        case malformed(String)
        case expired
        case revoked
    }

    struct RevocationReceipt: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var grantID: UUID
        var missionID: UUID
        var taskID: String
        var revokedAt: Date
        var revokedBy: String
        var reason: String
    }

    static let environmentKey = "THROTTLE_PLAN_AUTHORITY"
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var grantID: UUID
    var missionID: UUID
    var taskID: String
    var issuedAt: Date
    var expiresAt: Date
    /// Resolved paths a call may name as its project: the repository holding
    /// the plan and the task's own worktree, never a sibling.
    var projectRoots: [String]
    var author: String
    var operations: Set<Operation>

    init(
        projectRoots: [URL],
        author: String,
        operations: Set<Operation>,
        taskID: String,
        missionID: UUID,
        issuedAt: Date,
        expiresAt: Date,
        grantID: UUID = UUID()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.grantID = grantID
        self.missionID = missionID
        self.taskID = taskID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.projectRoots = Array(Set(projectRoots.map(Self.resolved))).sorted()
        self.author = author
        self.operations = operations
    }

    static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Loading

    /// nil when the environment names no descriptor (legacy caller).
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> Result<PlanMCPAuthority?, Failure> {
        guard let path = environment[environmentKey], !path.isEmpty else { return .success(nil) }
        let descriptorURL = URL(fileURLWithPath: path)
        switch readPrivateFile(descriptorURL) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let data):
            switch decode(data, now: now) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let authority?):
                switch revocationStatus(for: authority.grantID, descriptorURL: descriptorURL) {
                case .failure(let failure): return .failure(failure)
                case .success(true): return .failure(.revoked)
                case .success(false): return .success(authority)
                }
            case .success(nil):
                return .failure(.malformed("empty_authority"))
            }
        }
    }

    static func decode(_ data: Data, now: Date) -> Result<PlanMCPAuthority?, Failure> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let authority = try? decoder.decode(PlanMCPAuthority.self, from: data) else {
            return .failure(.malformed("undecodable"))
        }
        guard authority.schemaVersion == currentSchemaVersion else {
            return .failure(.malformed("schema_version"))
        }
        let rootsAreCanonical = authority.projectRoots.allSatisfy {
            $0.hasPrefix("/") && resolved(URL(fileURLWithPath: $0, isDirectory: true)) == $0
        }
        guard !authority.projectRoots.isEmpty,
              rootsAreCanonical,
              nonempty(authority.author),
              nonempty(authority.taskID),
              !authority.operations.isEmpty,
              authority.issuedAt < authority.expiresAt,
              authority.issuedAt <= now.addingTimeInterval(300) else {
            return .failure(.malformed("grant_fields"))
        }
        guard authority.expiresAt > now else { return .failure(.expired) }
        return .success(authority)
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    // MARK: - Decisions

    /// The refusal a call earns under this grant, or nil when it is within the
    /// exact project, author, task, operation and time window.
    func refusal(
        project: String?,
        author caller: String,
        operation: Operation,
        requestedTaskID: String?,
        now: Date = Date()
    ) -> String? {
        guard expiresAt > now else {
            return Self.refusal(for: .expired)
        }
        let requested = Self.resolved(URL(
            fileURLWithPath: project ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ))
        guard projectRoots.contains(requested) else {
            return "Refused: this runtime may only act on its own project."
        }
        guard caller == author else {
            return "Refused: this runtime speaks as \(author), not \(caller)."
        }
        if operation != .read, requestedTaskID != taskID {
            return "Refused: this grant is bound to task \(taskID)."
        }
        guard operations.contains(operation) else {
            return "Refused: this runtime was not granted \(operation.rawValue)."
        }
        return nil
    }

    static func refusal(for failure: Failure) -> String {
        switch failure {
        case .unreadable: return "Refused: the runtime's authority descriptor is unreadable."
        case .unsafe: return "Refused: the runtime's authority descriptor is not private to this user."
        case .malformed: return "Refused: the runtime's authority descriptor is malformed."
        case .expired: return "Refused: the runtime's authority descriptor has expired."
        case .revoked: return "Refused: the runtime's authority grant has been revoked."
        }
    }

    static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
