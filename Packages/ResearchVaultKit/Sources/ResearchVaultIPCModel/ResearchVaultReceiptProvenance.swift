import Foundation
import ResearchVaultModel

public struct ResearchVaultReceiptProvenance: Codable, Equatable, Sendable {
    public let receiptID: String
    public let sealedContentHash: String
    public let findingIndex: Int
    public let sources: [ResearchSource]

    public init(receiptID: String, sealedContentHash: String, findingIndex: Int, sources: [ResearchSource]) {
        self.receiptID = receiptID
        self.sealedContentHash = sealedContentHash
        self.findingIndex = findingIndex
        self.sources = sources
    }
}
