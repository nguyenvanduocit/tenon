// @domain: command-surface
import Foundation

/// The result of a fuzzy match: a score (higher is better) and the indices in the
/// candidate string that the query matched — the shell uses those to embolden the
/// matched characters in a palette row.
public struct FuzzyMatch: Equatable {
    public let score: Int
    public let matchedIndices: [Int]

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Subsequence fuzzy matching with fzf-style scoring — the palette's ranking
/// primitive. Pure and headless: `docs/tdd.md`'s fitness test ("can this rule be
/// asserted in `TenonCoreTests` without a window?") is yes.
///
/// Matching is greedy-forward and case-insensitive: the query matches when its
/// characters appear in `candidate` in order (not necessarily adjacent). Scoring
/// rewards matches at the start of the string, at word/separator/camelCase
/// boundaries, and in contiguous runs — so "Split Right" ranks above "Assist" for
/// the query "s". Score-maximising DP (fzf's full algorithm) is a later tuning
/// concern; greedy-forward is deterministic and enough for the command set sizes here.
public enum Fuzzy {
    private static let separators: Set<Character> = [" ", "/", "_", "-", ".", ":"]

    private static let startBonus = 8
    private static let boundaryBonus = 6
    private static let consecutiveBonus = 4
    private static let baseScore = 1
    private static let maxLeadingGapPenalty = 3

    /// Case, diacritics and stroked letters folded to one comparable form.
    ///
    /// Plain `lowercased()` is invariant folding, which is not how anyone reads their own
    /// alphabet: someone searching for `dong` expects to find `Đồng`, and `cafe` should find
    /// `Café`. Diacritics come off through Foundation's fold; the letters that carry a stroke
    /// rather than a mark — đ, ø, ł, ħ — are not diacritics to Unicode and need saying.
    ///
    /// The fold is deliberately locale-independent. Turkish casing maps `İ` to `ı` and `I` to
    /// `i`, so folding a command list by the reader's locale would move which names a single
    /// keystroke reaches — a search box that behaves differently on two machines is worse than
    /// one that behaves the same everywhere.
    ///
    /// One character in, one character out: a whole-string fold can change the length
    /// (`ß` → `ss`) and silently point the matched ranges at the wrong letters.
    private static let strokeFolding: [Character: Character] = [
        "đ": "d", "ø": "o", "ł": "l", "ħ": "h", "ŧ": "t", "ð": "d",
    ]

    static func folded(_ value: String) -> [Character] {
        value.map { character in
            let folded = String(character)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .first ?? character
            return strokeFolding[folded] ?? folded
        }
    }

    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let queryChars = folded(query)
        guard !queryChars.isEmpty else { return FuzzyMatch(score: 0, matchedIndices: []) }

        let candidateChars = Array(candidate)
        let lowerCandidate = folded(candidate)

        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryChars.count)

        var candidateIndex = 0
        for target in queryChars {
            var found = false
            while candidateIndex < lowerCandidate.count {
                if lowerCandidate[candidateIndex] == target {
                    matchedIndices.append(candidateIndex)
                    candidateIndex += 1
                    found = true
                    break
                }
                candidateIndex += 1
            }
            guard found else { return nil }
        }

        return FuzzyMatch(
            score: score(matchedIndices, in: candidateChars),
            matchedIndices: matchedIndices
        )
    }

    private static func score(_ indices: [Int], in candidate: [Character]) -> Int {
        var total = 0
        for (rank, position) in indices.enumerated() {
            var points = baseScore
            if position == 0 {
                points += startBonus
            } else if isBoundary(candidate, at: position) {
                points += boundaryBonus
            }
            if rank > 0, position == indices[rank - 1] + 1 {
                points += consecutiveBonus
            }
            total += points
        }
        if let first = indices.first {
            total -= min(first, maxLeadingGapPenalty)
        }
        return total
    }

    /// A character begins a "word" if the char before it is a separator, or if it is
    /// an uppercase letter following a lowercase letter or digit (camelCase).
    private static func isBoundary(_ candidate: [Character], at position: Int) -> Bool {
        guard position > 0 else { return true }
        let previous = candidate[position - 1]
        if separators.contains(previous) { return true }
        let current = candidate[position]
        if current.isUppercase, previous.isLowercase || previous.isNumber { return true }
        return false
    }
}
