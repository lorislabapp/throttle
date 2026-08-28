import Foundation
import ResearchVaultIngestion

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: research-vault-catalog-probe ROOT PROJECT\n".utf8))
    exit(64)
}

do {
    let batch = try DeepSearshCatalogImporter(root: URL(fileURLWithPath: arguments[1]))
        .load(projectKeys: [arguments[2]])
    let payload: [String: Any] = [
        "status": "pass",
        "project": arguments[2],
        "catalog_sha256": batch.evidence.catalogSHA256,
        "scanned_entries": batch.evidence.scannedEntries,
        "accepted_documents": batch.evidence.acceptedDocuments,
        "accepted_bytes": batch.evidence.acceptedBytes,
        "document_ids": batch.documents.map(\.documentID).sorted(),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("catalog probe failed\n".utf8))
    exit(1)
}
