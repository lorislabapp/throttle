import Foundation

extension CockpitTab {
    struct PauseGeneration: Equatable, Sendable {
        let sessionID: String?
        let spawnedAt: Date?
        let root: NativeProcessIdentity?
    }

    var pauseGeneration: PauseGeneration {
        PauseGeneration(sessionID: sessionId, spawnedAt: spawnedAt, root: rootProcessIdentity)
    }

    func canPause(generation: PauseGeneration) -> Bool {
        !isTransitioning && !isPaused && isSpawned && pauseGeneration == generation
    }
}
