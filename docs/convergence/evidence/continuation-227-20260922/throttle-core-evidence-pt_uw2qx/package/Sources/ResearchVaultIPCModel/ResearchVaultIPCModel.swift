// Compatibility re-export. The request/response types, their validation and
// the wire limits are canonical in the standalone `ThrottleVaultContract`
// package; product modules and the XPC service keep importing
// `ResearchVaultIPCModel`. Nothing is declared here so the two names cannot
// diverge.
@_exported import ThrottleVaultContract
