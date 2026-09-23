import Foundation
import ObjectiveC
import ThrottleVaultClient

/// Describes the two NSXPC protocols through the Objective-C runtime: the
/// required instance selectors and the runtime protocol name. The selectors are
/// what NSXPCConnection matches on the wire; the runtime name changes with the
/// defining module and is recorded for the evidence note only.
enum XPCInterfaceCapture {
    static func describe(_ proto: Protocol) -> [String: Any] {
        var count: UInt32 = 0
        var selectors: [String] = []
        if let list = protocol_copyMethodDescriptionList(proto, true, true, &count) {
            for index in 0 ..< Int(count) {
                if let selector = list[index].name {
                    selectors.append(NSStringFromSelector(selector))
                }
            }
            free(list)
        }
        return ["runtimeName": NSStringFromProtocol(proto), "selectors": selectors.sorted()]
    }

    static func capture() -> [String: Any] {
        [
            "queryProtocol": describe(ResearchVaultQueryXPCProtocol.self),
            "ownerProtocol": describe(ResearchVaultOwnerXPCProtocol.self),
            "receiptFileSuffix": ResearchVaultReceiptBatchReader.fileSuffix
        ]
    }

    static func selectors(_ capture: [String: Any], _ key: String) -> [String] {
        ((capture[key] as? [String: Any])?["selectors"] as? [String]) ?? []
    }
}
