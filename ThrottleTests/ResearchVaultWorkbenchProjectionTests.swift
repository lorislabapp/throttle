import Foundation
import ResearchVaultModel
import Testing
@testable import Throttle

@Suite("Research Vault Workbench projections")
struct ResearchVaultWorkbenchProjectionTests {
    @Test("a saved view filters and holds no corpus data, and an old view still shows everything")
    func savedViewFilters() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = ResearchSource(
            id: "s-1", kind: .url, locator: "https://example.com/a",
            observedAt: now.addingTimeInterval(-3 * 86_400),
            sha256: String(repeating: "a", count: 64)
        )
        let receipt = try ResearchReceipt.seal(
            sessionID: "session", agentID: "agent", projectKey: "throttle", question: "q",
            findings: [ResearchFinding(claim: "One", status: .verified, evidenceIDs: [source.id])],
            sources: [source], sensitivity: .internal,
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )

        #expect(ResearchVaultSavedView(name: "all", query: "q").matches(receipt, now: now),
                "a view saved before these filters existed restricts nothing")
        #expect(ResearchVaultSavedView(name: "v", query: "q", projectKey: "throttle")
            .matches(receipt, now: now))
        #expect(!ResearchVaultSavedView(name: "v", query: "q", projectKey: "other")
            .matches(receipt, now: now))
        #expect(ResearchVaultSavedView(name: "v", query: "q", evidenceStatus: .verified)
            .matches(receipt, now: now))
        #expect(!ResearchVaultSavedView(name: "v", query: "q", evidenceStatus: .contradicted)
            .matches(receipt, now: now))
        #expect(ResearchVaultSavedView(name: "v", query: "q", sourceKind: .url)
            .matches(receipt, now: now))
        #expect(!ResearchVaultSavedView(name: "v", query: "q", sourceKind: .repository)
            .matches(receipt, now: now))
        #expect(ResearchVaultSavedView(name: "v", query: "q", withinDays: 7)
            .matches(receipt, now: now))
        #expect(!ResearchVaultSavedView(name: "v", query: "q", withinDays: 1)
            .matches(receipt, now: now))
        #expect(ResearchVaultSavedView(name: "v", query: "q", withinDays: 0).withinDays == 1,
                "a window of no days would show nothing; it is clamped to one")

        // Filters travel; corpus text never does.
        let encoded = try JSONEncoder().encode(
            ResearchVaultSavedView(name: "v", query: "topic", sourceKind: .url, withinDays: 30)
        )
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"sourceKind\"") && json.contains("\"withinDays\""))
        #expect(!json.contains("example.com") && !json.contains("One"))
        let decoded = try JSONDecoder().decode(ResearchVaultSavedView.self, from: encoded)
        #expect(decoded.sourceKind == .url && decoded.withinDays == 30)

        // A view written by the previous version decodes with the new filters unset.
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"v","query":"q"}"#.utf8)
        let old = try JSONDecoder().decode(ResearchVaultSavedView.self, from: legacy)
        #expect(old.sourceKind == nil && old.withinDays == nil)
        #expect(old.matches(receipt, now: now))
    }

    @Test("a source says where it came from, what rests on it, and whether it moved")
    func sourceStanding() throws {
        let notebook = ResearchSource(
            id: "s-nlm", kind: .url,
            locator: "https://notebooklm.google.com/notebook/abc123def456789#source-index=4",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "a", count: 64)
        )
        #expect(ResearchVaultWorkbenchProjection.origin(of: notebook)
            == "NotebookLM · notebook abc123def456 · source 5",
            "the index is stored from zero and read from one")

        let exported = ResearchSource(
            id: "s-file", kind: .file, locator: "notebooklm-export/notes.md",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "b", count: 64)
        )
        #expect(ResearchVaultWorkbenchProjection.origin(of: exported) == "NotebookLM export file")

        let plain = ResearchSource(
            id: "s-plain", kind: .repository, locator: "https://example.com/a#source-index=2",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "c", count: 64)
        )
        #expect(ResearchVaultWorkbenchProjection.origin(of: plain) == "repository",
                "a fragment on another host is not a NotebookLM origin")

        #expect(ResearchVaultStandingText.source(claims: 0, hasMoved: false)
            == "No claim rests on it")
        #expect(ResearchVaultStandingText.source(claims: 2, hasMoved: true)
            == "2 claim(s) rest on it · content changed since")
    }

    @Test("only evidence a receipt actually carries counts towards a source")
    func claimCounts() throws {
        let source = ResearchSource(
            id: "source-1", kind: .file, locator: "/tmp/a.md",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "a", count: 64)
        )
        let receipt = try ResearchReceipt.seal(
            sessionID: "session", agentID: "agent", projectKey: "throttle", question: "q",
            findings: [
                ResearchFinding(claim: "One", status: .verified, evidenceIDs: [source.id]),
                ResearchFinding(claim: "Two", status: .supported, evidenceIDs: [source.id, source.id]),
                ResearchFinding(claim: "Three", status: .hypothesis, evidenceIDs: [])
            ],
            sources: [source], sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let counts = ResearchVaultWorkbenchProjection.claimCountsBySource(receipts: [receipt])
        #expect(counts == ["source-1": 2], "one finding citing a source twice still counts once")
        #expect(ResearchVaultWorkbenchProjection.claimCountsBySource(receipts: []).isEmpty)
    }

    @Test("preserves claim status and exposes revisions with impacted claims")
    func projections() throws {
        let first = try receipt(hash: String(repeating: "a", count: 64), day: 0, status: .verified)
        let second = try receipt(hash: String(repeating: "b", count: 64), day: 1, status: .contradicted)

        let claims = ResearchVaultWorkbenchProjection.claims(receipts: [first, second])
        #expect(claims.map(\.status) == [.contradicted, .open, .verified, .open])
        let revisions = ResearchVaultWorkbenchProjection.revisions(receipts: [first, second])
        #expect(revisions.count == 1)
        #expect(revisions[0].versions.count == 2)
        #expect(revisions[0].impactedClaims.count == 2)
        #expect(ResearchVaultWorkbenchProjection.taxonomyAudit(
            receipts: [first, second]
        ).orphanEvidenceReferences == 0)
    }

    @Test("saved views persist as filters without copying receipts")
    func savedViews() throws {
        let suite = "ResearchVaultSavedViewTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = ResearchVaultSavedView(
            name: "Contradictions", query: "transport", projectKey: "throttle",
            evidenceStatus: .contradicted
        )
        try ResearchVaultSavedViewStore.save([view], defaults: defaults)
        #expect(ResearchVaultSavedViewStore.load(defaults: defaults) == [view])
    }

    @Test("reasoning relation selectors include only reviewed evidence claims")
    @MainActor
    func reasoningSelectors() throws {
        let verified = try receipt(
            hash: String(repeating: "c", count: 64), day: 2, status: .verified
        )
        let open = try receipt(
            hash: String(repeating: "d", count: 64), day: 3, status: .open
        )
        let model = ResearchVaultWorkbenchModel()
        model.approvedReceipts = [open, verified]

        #expect(model.reasoningClaimReferences.count == 1)
        let reference = try #require(model.reasoningClaimReferences.first)
        #expect(reference.title == "Use TLS")
        #expect(reference.reference.receiptID == verified.receiptID)
    }

    private func receipt(
        hash: String,
        day: TimeInterval,
        status: ResearchEvidenceStatus
    ) throws -> ResearchReceipt {
        let source = ResearchSource(
            id: "source-\(Int(day))", kind: .repository, locator: "/repo/decision.md",
            observedAt: Date(timeIntervalSince1970: day * 86_400), sha256: hash
        )
        return try ResearchReceipt.seal(
            sessionID: "session", agentID: "agent", projectKey: "throttle",
            question: "Transport decision",
            findings: [.init(claim: "Use TLS", status: status, evidenceIDs: [source.id])],
            sources: [source], openQuestions: ["Which certificate?"],
            sensitivity: .internal, createdAt: source.observedAt
        )
    }
}
