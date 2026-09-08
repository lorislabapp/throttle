import Foundation

struct CockpitProcessProbe: Sendable {
    let id: UUID
    let identity: NativeProcessIdentity
    let spawnedAt: Date?

    @MainActor
    init?(_ tab: CockpitTab) {
        guard let identity = tab.rootProcessIdentity else { return nil }
        id = tab.id
        self.identity = identity
        spawnedAt = tab.spawnedAt
    }
}

struct CockpitSessionProbe: Sendable {
    let id: UUID
    let runtime: AgentRuntime
    let cwd: String
    let sessionId: String?
    let root: NativeProcessIdentity?
    let foreground: pid_t?
    let spawnedAt: Date?
    let choosing: Bool

    @MainActor
    init(_ tab: CockpitTab) {
        id = tab.id; runtime = tab.runtime; cwd = tab.cwd; sessionId = tab.sessionId
        root = tab.rootProcessIdentity; foreground = tab.foregroundProcessGroup
        spawnedAt = tab.spawnedAt; choosing = tab.isChoosingNativeSession
    }

    @MainActor
    func matches(_ tab: CockpitTab) -> Bool {
        tab.sessionId == sessionId && tab.spawnedAt == spawnedAt
            && tab.rootProcessIdentity == root && tab.foregroundProcessGroup == foreground
    }
}

struct CockpitSessionUsage: Sendable {
    struct Financial: Sendable {
        let eur: Double?
        let tokens: Int?
        let model: String?
        let impact: PromptCacheImpact?
    }
    let id: UUID
    var financial: Financial?
    var live = false
    var owned: NativeSessionBinding.Transcript?
    var loop: LoopSignal?
    var progress: CodexProgressSnapshot?
}
