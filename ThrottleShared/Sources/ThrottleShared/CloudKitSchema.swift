import Foundation

/// Single source of truth for the CloudKit mirror schema, shared by the Mac
/// publisher and the iOS subscriber so the record type, field keys, and
/// container id can never disagree across the two ends.
public enum CloudKitSchema {
    /// iCloud container shared by both apps. Declared in both entitlements.
    public static let containerID = "iCloud.com.lorislab.throttle"

    /// Record type holding the latest mirror snapshot.
    public static let recordType = "ThrottleSnapshot"

    /// The mirror is "latest state," so there is exactly one record per device,
    /// overwritten on each publish. A fixed name = a stable overwrite target.
    /// (Multi-Mac support later keys the name by device id.)
    public static func recordName(deviceID: String = "default") -> String {
        "current-\(deviceID)"
    }

    public enum Field {
        /// JSON-encoded `ThrottleMirrorSnapshot`, stored in `encryptedValues`
        /// for at-rest E2E encryption even inside the user's private DB.
        public static let payload = "payload"
        /// Plaintext, for cheap server-side sort/query without decoding the blob.
        public static let publishedAt = "publishedAt"
        public static let schemaVersion = "schemaVersion"
    }
}

/// App-Group handoff between the iOS app and its widget / Live-Activity extension.
public enum MirrorStorage {
    public static let appGroupID = "group.com.lorislab.throttle"
    /// Key under which the iOS app writes the latest encoded
    /// `ThrottleMirrorSnapshot` so the widget (a separate process) can render it.
    public static let latestSnapshotKey = "ThrottleMirrorLatestV1"
}
