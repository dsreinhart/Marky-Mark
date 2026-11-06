//
//  WritingGoal.swift
//  Markwright
//
//  Per-document writing goals (word or character targets, optional deadline).
//

import Foundation

struct WritingGoal: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case words, characters
        var id: String { rawValue }
        var label: String { self == .words ? "Words" : "Characters" }
    }

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case atLeast, atMost, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .atLeast: return "At least"
            case .atMost: return "At most"
            case .about: return "About"
            }
        }
    }

    var kind: Kind = .words
    var mode: Mode = .atLeast
    var target: Int = 1000
    var deadline: Date? = nil

    func current(from stats: TextStatistics) -> Int {
        kind == .words ? stats.words : stats.characters
    }

    /// 0...1 progress toward the target.
    func fraction(current: Int) -> Double {
        guard target > 0 else { return 0 }
        return min(Double(current) / Double(target), 1)
    }

    /// Whether the goal is currently satisfied.
    func isMet(current: Int) -> Bool {
        switch mode {
        case .atLeast: return current >= target
        case .atMost: return current <= target
        case .about: return abs(current - target) <= max(target / 10, 1)
        }
    }

    var daysRemaining: Int? {
        guard let deadline else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.startOfDay(for: deadline)
        return Calendar.current.dateComponents([.day], from: start, to: end).day
    }
}

@MainActor
@Observable
final class GoalStore {
    static let shared = GoalStore()

    private(set) var goals: [String: WritingGoal] = [:]
    private static let key = "writingGoals"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: WritingGoal].self, from: data) {
            goals = decoded
        }
    }

    func goal(for key: String) -> WritingGoal? {
        goals[key]
    }

    func set(_ goal: WritingGoal?, for key: String) {
        goals[key] = goal
        persist()
    }

    func rename(from old: String, to new: String) {
        guard old != new, let goal = goals[old] else { return }
        goals[new] = goal
        goals[old] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(goals) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
