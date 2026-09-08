import Foundation

/// The widget reads only the app's explicitly published, identity-verified view.
/// The private restoration cache is deliberately not a fallback.
public enum MirrorWidgetPublication {
    public static let snapshotKey = "ThrottleVerifiedWidgetSnapshotV1"

    public static func read(from defaults: UserDefaults) -> ThrottleMirrorSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? ThrottleMirrorSnapshot.decoded(from: data) else { return nil }
        return snapshot.withoutSecrets
    }
}
