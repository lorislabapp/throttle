import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

extension SQLCipherReceiptStore {

    func decodeAndValidate(_ payload: Data) throws -> ResearchReceipt {
        let receipt = try decoder.decode(ResearchReceipt.self, from: payload)
        try ResearchReceiptValidator.validate(receipt)
        return receipt
    }

    static func projectFilter(
        _ projects: Set<String>,
        firstParameter: Int
    ) -> (String, [SQLCipherBind]) {
        let sorted = projects.sorted()
        let placeholders = sorted.indices.map { "?" + String(firstParameter + $0) }
        return (placeholders.joined(separator: ", "), sorted.map(SQLCipherBind.text))
    }

    static func fold(_ token: String) -> String {
        token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func safeFTSQuery(_ query: String) throws -> String {
        let tokens = query
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(32)
            .map { String($0.prefix(64)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ClaimSearchError.emptyQuery }

        // Case separates an acronym from a function word, so the stoplist is
        // consulted only for a token written entirely in lower case. In this
        // corpus the collisions ARE the subject matter — AI, CAN (the bus), IT,
        // US, EU — and they are capitalised, while "le", "du" and "on" are not.
        //
        // Diacritics are folded before the lookup because the index tokenizer is
        // configured with remove_diacritics 2: it stores "ete" for "été", so
        // comparing a raw token missed every accented French function word the
        // list exists to catch.
        let content = tokens.filter { token in
            token.contains(where: \.isUppercase) || !ftsStopwords.contains(Self.fold(token))
        }
        // Keep the function words only when nothing else is left: an empty
        // query would return nothing at all, which is worse than a noisy match.
        let effective = (content.isEmpty ? tokens : content).map { $0.lowercased() }
        return effective.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
