import Foundation

enum PlanMCPAuthorityLifecycle {
    enum CloseResult: Equatable {
        case inactive
        case revoked(PlanMCPAuthority.RevocationReceipt)
        case failed(String)
    }

    /// Revokes a task grant when its owning cockpit session is explicitly
    /// closed. Hibernation does not call this path because that session can wake.
    static func closeSession(
        launchEnvironment: [String],
        actor: String,
        reason: String = "cockpit_session_closed",
        now: Date = Date()
    ) -> CloseResult {
        let prefix = PlanMCPAuthority.environmentKey + "="
        let values = launchEnvironment.filter { $0.hasPrefix(prefix) }
        guard !values.isEmpty else { return .inactive }
        guard values.count == 1 else { return .failed("authority_environment_ambiguous") }
        let path = String(values[0].dropFirst(prefix.count))
        guard path.hasPrefix("/"), !path.isEmpty else {
            return .failed("authority_environment_invalid")
        }
        let descriptor = URL(fileURLWithPath: path)
        let environment = [PlanMCPAuthority.environmentKey: path]
        switch PlanMCPAuthority.load(environment: environment, now: now) {
        case .failure(.expired):
            return .inactive
        case .failure(.revoked):
            do {
                return .revoked(try PlanMCPAuthority.revoke(
                    descriptorURL: descriptor,
                    by: actor,
                    reason: reason,
                    now: now
                ))
            } catch {
                return .failed("authority_revocation_receipt_unreadable")
            }
        case .failure:
            return .failed("authority_descriptor_cannot_be_revoked")
        case .success(nil):
            return .failed("authority_descriptor_missing")
        case .success:
            do {
                return .revoked(try PlanMCPAuthority.revoke(
                    descriptorURL: descriptor,
                    by: actor,
                    reason: reason,
                    now: now
                ))
            } catch {
                return .failed("authority_revocation_failed")
            }
        }
    }
}
