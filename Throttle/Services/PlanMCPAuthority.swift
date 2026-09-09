import Darwin
import Foundation

/// Who this MCP process may act as, and on what.
///
/// For a stdio server the caller's identity is the operating system's: whoever
/// launched the process under this user already holds its rights, and the MCP
/// specification (2026-07-28, Authorization, "Protocol Requirements") says a
/// stdio server takes its credentials from the environment rather than from an
/// authorization flow. What the environment can add is a *narrowing*: a
/// descriptor the launcher writes for one runtime, naming the project root it
/// may touch, the author it speaks as and the operations it may perform.
///
/// No descriptor means a legacy caller and unchanged behaviour. A descriptor
/// that is present is enforced on every call; one that is present but
/// unreadable, world-readable, malformed or expired refuses every mutation,
/// because a launcher that meant to narrow rights must not silently widen them.
struct PlanMCPAuthority: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable, CaseIterable { case read, claim, event, verdict }

    enum Failure: Error, Equatable, Sendable {
        case unreadable(String)
        case unsafe(String)
        case malformed(String)
        case expired
    }

    static let environmentKey = "THROTTLE_PLAN_AUTHORITY"
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Resolved paths a call may name as its project: the repository holding
    /// the plan and the task's own worktree, never a sibling.
    var projectRoots: [String]
    var author: String
    var operations: Set<Operation>
    var expiresAt: Date?

    init(projectRoots: [URL], author: String, operations: Set<Operation>, expiresAt: Date?) {
        schemaVersion = Self.currentSchemaVersion
        self.projectRoots = Array(Set(projectRoots.map(Self.resolved))).sorted()
        self.author = author
        self.operations = operations
        self.expiresAt = expiresAt
    }

    static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Loading

    /// nil when the environment names no descriptor (legacy caller).
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     now: Date = Date()) -> Result<PlanMCPAuthority?, Failure> {
        guard let path = environment[environmentKey], !path.isEmpty else { return .success(nil) }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.unreadable(path)) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.unreadable(path))
        }
        // The descriptor is this user's private grant: any group or world bit,
        // or a foreign owner, and it may have been planted or read by another.
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= 64 * 1024 else {
            return .failure(.unsafe(path))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return .failure(.unreadable(path)) }
        return decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date) -> Result<PlanMCPAuthority?, Failure> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let authority = try? decoder.decode(PlanMCPAuthority.self, from: data) else {
            return .failure(.malformed("undecodable"))
        }
        guard authority.schemaVersion == currentSchemaVersion else { return .failure(.malformed("schema_version")) }
        guard !authority.projectRoots.isEmpty, authority.projectRoots.allSatisfy({ $0.hasPrefix("/") }),
              !authority.author.isEmpty else {
            return .failure(.malformed("project_roots_or_author"))
        }
        if let expiresAt = authority.expiresAt, expiresAt <= now { return .failure(.expired) }
        return .success(authority)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - Decisions

    /// The refusal a call earns under this descriptor, or nil when it is within
    /// the grant. The project is compared as a resolved path, so a symlink or a
    /// trailing slash cannot reach a sibling repository.
    func refusal(project: String?, author caller: String, operation: Operation) -> String? {
        let requested = Self.resolved(URL(fileURLWithPath: project ?? FileManager.default.currentDirectoryPath,
                                          isDirectory: true))
        guard projectRoots.contains(requested) else {
            return "Refused: this runtime may only act on its own project."
        }
        guard caller == author else {
            return "Refused: this runtime speaks as \(author), not \(caller)."
        }
        guard operations.contains(operation) else {
            return "Refused: this runtime was not granted \(operation.rawValue)."
        }
        return nil
    }

    /// Every mutation is refused when a configured descriptor cannot be trusted.
    static func refusal(for failure: Failure) -> String {
        switch failure {
        case .unreadable: return "Refused: the runtime's authority descriptor is unreadable."
        case .unsafe: return "Refused: the runtime's authority descriptor is not private to this user."
        case .malformed: return "Refused: the runtime's authority descriptor is malformed."
        case .expired: return "Refused: the runtime's authority descriptor has expired."
        }
    }
}
