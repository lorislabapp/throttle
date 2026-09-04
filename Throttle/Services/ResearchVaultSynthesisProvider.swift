import ResearchVaultSynthesis

struct ResearchVaultEmbeddedSynthesisProvider: ResearchVaultSynthesisProvider {
    let backend = ResearchVaultSynthesisBackend.sameDevice

    func generate(prompt: String, maximumOutputCharacters: Int) async throws -> String {
        let tokenBudget = min(max(maximumOutputCharacters / 4, 128), 1_024)
        return try await EmbeddedModelRuntime.shared.researchVaultSynthesize(
            prompt: prompt,
            maxTokens: tokenBudget
        )
    }
}
