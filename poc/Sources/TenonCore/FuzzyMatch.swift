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

    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let queryChars = Array(query.lowercased())
        guard !queryChars.isEmpty else { return FuzzyMatch(score: 0, matchedIndices: []) }

        let candidateChars = Array(candidate)
        let lowerCandidate = Array(candidate.lowercased())

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
