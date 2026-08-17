import Foundation

struct WebPageLink: Sendable, Equatable {
    let url: String
    let label: String
}

/// Deterministic next-hop planner for web research. It never clicks or submits:
/// it ranks safe visible links so an agent can deliberately choose the next page.
enum WebNavigationPlanner {
    static func ranked(_ links: [WebPageLink], query: String?, baseURL: String, limit: Int = 12) -> [WebPageLink] {
        let baseHost = URL(string: baseURL)?.host?.lowercased()
        let terms = Set((query ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 })
        var seen = Set<String>()
        var candidates: [(link: WebPageLink, score: Int)] = []
        for link in links {
            guard let url = URL(string: link.url),
                  WebURLPolicy.rejectionReason(for: url, resolveDNS: false) == nil else { continue }
            let normalized = WebResearchCache.normalize(link.url)
            guard seen.insert(normalized).inserted else { continue }
            let haystack = (link.label + " " + link.url).lowercased()
            var score = terms.reduce(0) { $0 + (haystack.contains($1) ? 10 : 0) }
            if url.host?.lowercased() == baseHost { score += 3 }
            if !link.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 2 }
            candidates.append((WebPageLink(url: normalized, label: clean(link.label)), score))
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.link.url < $1.link.url
        }.prefix(max(0, min(limit, 30))).map(\.link)
    }

    private static func clean(_ label: String) -> String {
        label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description
    }
}
