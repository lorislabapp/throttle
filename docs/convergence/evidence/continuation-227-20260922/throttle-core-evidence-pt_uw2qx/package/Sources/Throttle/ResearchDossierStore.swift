import Darwin
import Foundation

/// The project mutation lock serializes read/append/write across all callers.
/// A corrupt existing dossier is evidence of a problem, never an empty dossier
/// that a new finding may silently overwrite.
final class ResearchDossierStore: @unchecked Sendable {
    private let root: URL
    private let files = FileManager.default

    init(projectRoot: URL) { root = projectRoot.standardizedFileURL.resolvingSymlinksInPath() }

    private var dossierURL: URL { root.appendingPathComponent(".throttle/research.json") }
    private static let maximumBytes = 4 * 1_024 * 1_024

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Compatibility for existing UI callers. Mutation uses loadValidated.
    func load(projectId: String = "") -> ResearchDossier {
        (try? loadValidated(projectId: projectId)) ?? ResearchDossier(projectId: projectId)
    }

    func loadValidated(projectId: String = "") throws -> ResearchDossier {
        guard dossierURL.deletingLastPathComponent().resolvingSymlinksInPath()
            == dossierURL.deletingLastPathComponent() else { throw ResearchDossierError.unsafeStorage }
        let descriptor = Darwin.open(dossierURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return ResearchDossier(projectId: projectId) }
            throw ResearchDossierError.unsafeStorage
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size <= Self.maximumBytes else {
            throw ResearchDossierError.unsafeStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1),
              data.count == info.st_size, data.count <= Self.maximumBytes,
              let dossier = try? Self.decoder.decode(ResearchDossier.self, from: data) else {
            throw ResearchDossierError.corruptDossier
        }
        return dossier
    }

    @discardableResult
    func record(_ finding: ResearchFinding, projectId: String = "",
                authorizeMutation: () -> String? = { nil }) throws -> ResearchDossier {
        guard !finding.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchDossierError.sourceRequired
        }
        guard !finding.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchDossierError.claimRequired
        }
        if let refusal = authorizeMutation() { throw ResearchDossierError.unauthorized(refusal) }
        return try PlanStore(projectRoot: root).mutate { _ in
            if let refusal = authorizeMutation() { throw ResearchDossierError.unauthorized(refusal) }
            var dossier = try loadValidated(projectId: projectId)
            dossier.findings.append(finding)
            let data = try Self.encoder.encode(dossier)
            guard data.count <= Self.maximumBytes else { throw ResearchDossierError.unsafeStorage }
            if let refusal = authorizeMutation() { throw ResearchDossierError.unauthorized(refusal) }
            try data.write(to: dossierURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dossierURL.path)
            try synchronize(dossierURL, directory: false)
            try synchronize(dossierURL.deletingLastPathComponent(), directory: true)
            return dossier
        }
    }

    private func synchronize(_ url: URL, directory: Bool) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw ResearchDossierError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        try PlanStore.synchronize(descriptor)
    }
}

enum ResearchDossierError: Error, Equatable {
    case sourceRequired
    case claimRequired
    case unsafeStorage
    case corruptDossier
    case unauthorized(String)
}
