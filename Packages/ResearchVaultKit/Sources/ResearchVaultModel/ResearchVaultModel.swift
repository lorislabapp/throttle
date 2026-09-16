// The receipt format, its validator and the client request/response contract
// are canonical in the standalone `ThrottleVaultContract` package. This product
// module re-exports them so every existing `import ResearchVaultModel` keeps
// compiling unchanged, and keeps only what the service side owns: the storage
// review state below and the immutable endpoint grant in `VaultAuthorization`.
@_exported import ThrottleVaultContract

/// Human-review state of imported material. Rejection is not a stored state:
/// rejecting deletes the rows. Existing pre-v4 rows are grandfathered as
/// approved by the SQLCipher migration.
public enum ResearchReviewState: String, Codable, Sendable, CaseIterable {
    case quarantined
    case approved
}
