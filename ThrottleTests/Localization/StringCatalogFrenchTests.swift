import Foundation
import XCTest

private struct CatalogUnit: Decodable { let state: String; let value: String }
private struct CatalogLocalization: Decodable { let stringUnit: CatalogUnit? }
private struct CatalogEntry: Decodable { let localizations: [String: CatalogLocalization]? }
private struct Catalog: Decodable { let strings: [String: CatalogEntry] }

/// Reads the String Catalog from the source tree, so a missing or broken French
/// entry fails here instead of silently showing English in a French session.
final class StringCatalogFrenchTests: XCTestCase {
    private func catalog() throws -> Catalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Throttle/Resources/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    /// Positional forms (`%1$@`) are how a translation reorders arguments, so they
    /// count as the same placeholder as the key's `%@`: the index is dropped.
    private func placeholders(_ text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:%|lld|@)")
        let range = NSRange(text.startIndex..., in: text)
        return (pattern?.matches(in: text, range: range) ?? [])
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .map { $0.replacingOccurrences(of: "[0-9]+\\$", with: "", options: .regularExpression) }
            .sorted()
    }

    func testEveryFrenchValueKeepsTheKeysPlaceholders() throws {
        for (key, entry) in try catalog().strings {
            guard let french = entry.localizations?["fr"]?.stringUnit else { continue }
            XCTAssertEqual(placeholders(key), placeholders(french.value), key)
            XCTAssertFalse(french.value.isEmpty, key)
        }
    }

    func testTheSurfacesAddedFor370AreTranslated() throws {
        let strings = try catalog().strings
        let keys = [
            "%lld session(s) waiting on you after %@",
            "Still working, last spoke %@ ago",
            "Quiet: %@ and %lld more",
            "WAITING ON YOU",
            "€%@ spent",
            "leaving this session strands %@ of warm context (~€%@ to rebuild)",
            "%lld claim(s) rest on it",
            "On — %lld source(s) at %@",
            "Review & apply %lld change(s)",
            "Throttle will hibernate the source first, then start a fresh %@ session with the reviewed packet. "
                + "Only one agent writes in this checkout."
        ]
        for key in keys {
            let french = strings[key]?.localizations?["fr"]?.stringUnit
            XCTAssertEqual(french?.state, "translated", key)
        }
    }
}
