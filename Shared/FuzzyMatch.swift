//
//  FuzzyMatch.swift
//  Markwright
//
//  Quick Open's matching: "trn" finds "Trip notes".
//

import Foundation

nonisolated enum FuzzyMatch {
    /// Subsequence match with a bonus for consecutive and word-start hits.
    static func score(_ query: String, in text: String) -> Int? {
        var score = 0
        var index = text.startIndex
        var previous: String.Index? = nil
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return nil }
            score += 1
            if let previous, text.index(after: previous) == found { score += 3 }
            if found == text.startIndex || text[text.index(before: found)] == " " { score += 2 }
            previous = found
            index = text.index(after: found)
        }
        return score
    }
}
