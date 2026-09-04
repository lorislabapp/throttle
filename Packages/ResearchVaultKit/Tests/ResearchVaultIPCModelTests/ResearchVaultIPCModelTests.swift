import Foundation
import ResearchVaultIPCModel
import Testing

@Suite("Research Vault IPC model")
struct ResearchVaultIPCModelTests {
    @Test("query contract carries only a narrowing project scope")
    func secretlessRequest() throws {
        let request = try ResearchVaultSearchRequest(
            query: "authenticated local research",
            limit: 4,
            maximumCharacters: 2_048
        ).validated()
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "contractVersion", "query", "limit", "maximumCharacters",
        ])
        #expect(object["projectKeys"] == nil)
        #expect(object["maximumSensitivity"] == nil)
        #expect(object["database"] == nil)
        #expect(object["key"] == nil)
    }

    @Test("project scope is normalized by strict validation")
    func projectScopeValidation() throws {
        let request = try ResearchVaultSearchRequest(
            query: "evidence",
            projectKeys: ["throttle", "cheatcode"]
        ).validated()
        #expect(request.projectKeys == ["throttle", "cheatcode"])
        #expect(throws: ResearchVaultIPCValidationError.invalidProjectScope) {
            try ResearchVaultSearchRequest(query: "evidence", projectKeys: ["../private"])
                .validated()
        }
        #expect(throws: ResearchVaultIPCValidationError.invalidProjectScope) {
            try ResearchVaultSearchRequest(query: "evidence", projectKeys: [])
                .validated()
        }
    }

    @Test("query validation is closed and bounded")
    func validation() {
        #expect(throws: ResearchVaultIPCValidationError.invalidQuery) {
            try ResearchVaultSearchRequest(query: " ").validated()
        }
        #expect(throws: ResearchVaultIPCValidationError.invalidLimit) {
            try ResearchVaultSearchRequest(query: "ok", limit: 21).validated()
        }
        #expect(throws: ResearchVaultIPCValidationError.invalidMaximumCharacters) {
            try ResearchVaultSearchRequest(query: "ok", maximumCharacters: 51_000)
                .validated()
        }
    }
}
