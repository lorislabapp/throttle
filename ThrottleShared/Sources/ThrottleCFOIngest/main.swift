import Foundation
import ThrottleShared

struct Output: Codable {
    let inserted: Bool
    let acceptedEvents: Int
    let inputBytes: UInt64
    let outputBytes: UInt64
    let estimatedTokensBefore: UInt64
    let estimatedTokensAfter: UInt64
    let estimatedTokensSaved: UInt64
}

do {
    guard let path = ProcessInfo.processInfo.environment["THROTTLE_CFO_JOURNAL"], !path.isEmpty else {
        throw CocoaError(.fileNoSuchFile)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let receipt = try JSONDecoder().decode(GoliathControlPlane.Receipt.self, from: data)
    let result = try GoliathControlPlane.DurableAccountingStore(fileURL: URL(fileURLWithPath: path))
        .consume(receipt)
    let snapshot = result.snapshot
    let output = Output(
        inserted: result.inserted, acceptedEvents: snapshot.acceptedEvents,
        inputBytes: snapshot.inputBytes, outputBytes: snapshot.outputBytes,
        estimatedTokensBefore: snapshot.estimatedTokensBefore,
        estimatedTokensAfter: snapshot.estimatedTokensAfter,
        estimatedTokensSaved: snapshot.estimatedTokensSaved)
    FileHandle.standardOutput.write(try JSONEncoder().encode(output))
} catch {
    FileHandle.standardError.write(Data("throttle-cfo-ingest: \(error)\n".utf8))
    exit(1)
}
