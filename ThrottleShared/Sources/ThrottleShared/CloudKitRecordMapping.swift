import Foundation
import CloudKit

/// Maps `ThrottleMirrorSnapshot` ↔ `CKRecord`. The whole snapshot rides as one
/// JSON blob in `encryptedValues[payload]`; only `publishedAt` + `schemaVersion`
/// are exposed in the clear for querying/sorting. This keeps the CloudKit schema
/// frozen forever — new payload fields never require the human-gated Production
/// schema redeploy.
public enum CloudKitRecordMapping {

    /// Build (or overwrite) the `current` record from a snapshot. Pass an
    /// existing fetched record to preserve its change-tag for a clean save.
    public static func record(from snap: ThrottleMirrorSnapshot,
                              deviceID: String = "default",
                              existing: CKRecord? = nil) throws -> CKRecord {
        let id = CKRecord.ID(recordName: CloudKitSchema.recordName(deviceID: deviceID))
        let record = existing ?? CKRecord(recordType: CloudKitSchema.recordType, recordID: id)
        record.encryptedValues[CloudKitSchema.Field.payload] = try snap.encoded() as NSData
        record[CloudKitSchema.Field.publishedAt] = snap.publishedAt as NSDate
        record[CloudKitSchema.Field.schemaVersion] = snap.schemaVersion as NSNumber
        return record
    }

    public enum MappingError: Error, Equatable {
        case missingPayload
        case unsupportedSchema(Int)
    }

    /// Decode a fetched record back into a snapshot. Tolerates newer schema
    /// versions up to the payload staying decodable; rejects only if the blob
    /// is absent.
    public static func snapshot(from record: CKRecord) throws -> ThrottleMirrorSnapshot {
        guard let data = record.encryptedValues[CloudKitSchema.Field.payload] as? Data else {
            throw MappingError.missingPayload
        }
        return try ThrottleMirrorSnapshot.decoded(from: data)
    }
}
