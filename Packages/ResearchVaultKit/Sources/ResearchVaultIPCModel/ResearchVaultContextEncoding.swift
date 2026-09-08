import Foundation

public enum ResearchVaultContextEncodingError: Error, Sendable {
    case responseTooLarge
}

extension ResearchVaultContextBundle {
    /// One wire representation for both the assembler's budget and the XPC reply.
    /// Excerpt characters alone do not bound titles, paths or source provenance.
    public func encodedForIPC() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= ResearchVaultIPCContract.maximumResponseBytes else {
            throw ResearchVaultContextEncodingError.responseTooLarge
        }
        return data
    }
}
