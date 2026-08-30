import Foundation

/// Stores the viability dossier beside the plan, at `.throttle/research.json`.
///
/// Append-only in practice: findings are added, never edited, so a later verdict
/// can be traced back to what was known when it was written.
final class ResearchDossierStore: @unchecked Sendable {

    private let root: URL
    private let files = FileManager.default
    private let lock = NSLock()

    init(projectRoot: URL) { self.root = projectRoot }

    private var dossierURL: URL {
        root.appendingPathComponent(".throttle/research.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load(projectId: String = "") -> ResearchDossier {
        lock.lock(); defer { lock.unlock() }
        return loadImpl(projectId: projectId)
    }

    private func loadImpl(projectId: String) -> ResearchDossier {
        guard let data = files.contents(atPath: dossierURL.path),
              let dossier = try? Self.decoder.decode(ResearchDossier.self, from: data) else {
            return ResearchDossier(projectId: projectId)
        }
        return dossier
    }

    /// Refuses a finding with no source. The whole value of the dossier is that
    /// every line in it can be checked.
    @discardableResult
    func record(_ finding: ResearchFinding, projectId: String = "") throws -> ResearchDossier {
        guard !finding.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchDossierError.sourceRequired
        }
        guard !finding.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchDossierError.claimRequired
        }
        lock.lock(); defer { lock.unlock() }
        var dossier = loadImpl(projectId: projectId)
        dossier.findings.append(finding)
        try files.createDirectory(at: root.appendingPathComponent(".throttle", isDirectory: true),
                                  withIntermediateDirectories: true)
        try Self.encoder.encode(dossier).write(to: dossierURL, options: .atomic)
        return dossier
    }
}

enum ResearchDossierError: Error, Equatable {
    case sourceRequired
    case claimRequired
}
