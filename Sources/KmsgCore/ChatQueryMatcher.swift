import Foundation

/// Fuzzy chat-name matching used to pick windows and chat-list rows for a query.
/// (Moved verbatim from ChatWindowResolver so the rules can be unit tested.)
public enum ChatQueryMatcher {
    public static let exactScore = 12_000

    public static func score(query: String, candidate: String) -> Int {
        let queryNormalized = normalize(query)
        let candidateNormalized = normalize(candidate)
        guard !queryNormalized.isEmpty, !candidateNormalized.isEmpty else { return 0 }

        if queryNormalized == candidateNormalized {
            return exactScore
        }
        if candidateNormalized.hasPrefix(queryNormalized) {
            return 10_500
        }
        if candidateNormalized.contains(queryNormalized) {
            return 9_800
        }
        if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= 2 {
            return 8_800
        }

        let queryVariants = honorificVariants(of: queryNormalized)
        let candidateVariants = honorificVariants(of: candidateNormalized)
        var best = 0

        for queryVariant in queryVariants where !queryVariant.isEmpty {
            for candidateVariant in candidateVariants where !candidateVariant.isEmpty {
                if queryVariant == candidateVariant {
                    best = max(best, 8_700)
                    continue
                }
                if candidateVariant.hasPrefix(queryVariant) {
                    best = max(best, 8_400)
                    continue
                }
                if candidateVariant.contains(queryVariant) {
                    best = max(best, 8_200)
                    continue
                }
                if queryVariant.contains(candidateVariant), candidateVariant.count >= 2 {
                    best = max(best, 7_900)
                }
            }
        }

        if best > 0 {
            return best
        }

        let minLength = min(queryNormalized.count, candidateNormalized.count)
        if minLength >= 2 {
            let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
            let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
            if longest.contains(shortest) {
                return 6_600
            }
        }

        return 0
    }

    public static func normalize(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    public static func honorificVariants(of text: String) -> [String] {
        let suffixes = ["선생님", "님", "씨"]
        var variants = Set<String>([text])
        for suffix in suffixes where text.hasSuffix(suffix) {
            let candidate = String(text.dropLast(suffix.count))
            if !candidate.isEmpty {
                variants.insert(candidate)
            }
        }
        return Array(variants)
    }

    /// Picks the row to open for a name query: the first exact match wins; otherwise the single
    /// best fuzzy match. Returns `.ambiguous` when several rows share the best fuzzy score.
    public static func choose(query: String, titles: [(index: Int, title: String)]) -> ChatQueryChoice {
        var best: [(index: Int, title: String)] = []
        var bestScore = 0
        for entry in titles {
            let score = score(query: query, candidate: entry.title)
            if score == exactScore {
                return .match(index: entry.index, title: entry.title, exact: true)
            }
            if score > bestScore {
                bestScore = score
                best = [entry]
            } else if score == bestScore, score > 0 {
                best.append(entry)
            }
        }
        if best.count == 1, let only = best.first {
            return .match(index: only.index, title: only.title, exact: false)
        }
        if best.count > 1 {
            return .ambiguous(best.map(\.title))
        }
        return .none
    }
}

public enum ChatQueryChoice: Equatable, Sendable {
    case match(index: Int, title: String, exact: Bool)
    case ambiguous([String])
    case none
}
