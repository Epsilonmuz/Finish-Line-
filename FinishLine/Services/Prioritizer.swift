import Foundation

/// The cues you give the prioritizer on the Now screen.
struct Cues {
    var minutes: Int        // time available
    var energy: Difficulty  // low = easy, medium, high = hard
    var atDesk: Bool        // at the Mac, or away with just the phone
}

enum SuggestionKind: String {
    case fixBuild, nextStep, writeStep, reviewIdeas, nothing
}

struct Suggestion: Identifiable {
    let id = UUID()
    let kind: SuggestionKind
    let project: Project?
    let title: String
    let detail: String
    let reason: String
    let score: Double
    /// Which cue contributed most; used to learn from skips.
    let topCue: String
}

/// Scores every candidate task against your cues. Each cue is research-inspired
/// (task fit, energy match, goal-gradient, broken builds, staleness), but the
/// weighting is our own design, so it learns from what you skip or finish.
enum Prioritizer {
    static let cueNames = ["fit", "energy", "place", "ci", "gradient", "stale"]
    private static let weightsKey = "prioritizerWeights"

    static var weights: [String: Double] {
        get {
            var w = (UserDefaults.standard.dictionary(forKey: weightsKey) as? [String: Double]) ?? [:]
            for c in cueNames where w[c] == nil { w[c] = 1.0 }
            return w
        }
        set { UserDefaults.standard.set(newValue, forKey: weightsKey) }
    }

    static func resetLearning() {
        UserDefaults.standard.removeObject(forKey: weightsKey)
    }

    private struct Candidate {
        let kind: SuggestionKind
        let project: Project
        let title: String
        let detail: String
        let minutes: Int
        let difficulty: Difficulty
        let needsMac: Bool
    }

    static func rank(projects: [Project], ideaCount: Int, cues: Cues) -> [Suggestion] {
        let active = projects.filter { $0.state == .active }
        var tasks: [Candidate] = []

        for p in active {
            if p.ciFailing {
                tasks.append(Candidate(kind: .fixBuild, project: p,
                                  title: "Fix the failing build in \(p.name)",
                                  detail: p.ciSummary,
                                  minutes: 30, difficulty: .medium, needsMac: true))
            }
            if p.hasNextStep {
                tasks.append(Candidate(kind: .nextStep, project: p,
                                  title: p.nextThen,
                                  detail: p.nextStepSentence,
                                  minutes: p.nextMinutes, difficulty: p.nextDifficulty, needsMac: p.nextNeedsMac))
            } else {
                tasks.append(Candidate(kind: .writeStep, project: p,
                                  title: "Write the next if-then step for \(p.name)",
                                  detail: "Two minutes. A clear next step is the best-supported trick in the whole app.",
                                  minutes: 5, difficulty: .easy, needsMac: false))
            }
        }

        let w = weights
        var out: [Suggestion] = []
        for t in tasks {
            var c: [String: Double] = [:]
            c["fit"] = t.minutes <= cues.minutes ? 1.0 : max(0, 1 - Double(t.minutes - cues.minutes) / Double(max(t.minutes, 1)))
            c["energy"] = 1.0 - Double(abs(t.difficulty.rawValue - cues.energy.rawValue)) / 2.0
            c["place"] = (t.needsMac && !cues.atDesk) ? 0.0 : 1.0
            c["ci"] = t.kind == .fixBuild ? 1.0 : 0.0
            c["gradient"] = Double(t.project.milestone.rawValue + 1) / Double(Milestone.allCases.count)
            c["stale"] = min(1.0, Double(t.project.daysSinceProgress) / 14.0)

            var score = 0.0
            var best = ("fit", -1.0)
            for name in cueNames {
                let part = (w[name] ?? 1) * (c[name] ?? 0)
                score += part
                if name != "place" && part > best.1 { best = (name, part) }
            }
            // Mac-only work while you're away is almost never the right pick.
            if c["place"] == 0 { score *= 0.2 }
            // A red build always explains itself as the reason.
            if t.kind == .fixBuild { best = ("ci", 1.0) }

            out.append(Suggestion(kind: t.kind, project: t.project, title: t.title, detail: t.detail,
                                  reason: reason(best.0, task: t, cues: cues), score: score, topCue: best.0))
        }

        // Away from the desk with parked ideas on review day: offer the weekly review.
        let isSunday = Calendar.current.component(.weekday, from: .now) == 1
        if !cues.atDesk && isSunday && ideaCount > 0 {
            out.append(Suggestion(kind: .reviewIdeas, project: nil,
                                  title: "Weekly review: pick at most one idea",
                                  detail: "\(ideaCount) ideas parked in the Vault.",
                                  reason: "It's review day and you're away from the Mac",
                                  score: 3.5, topCue: "place"))
        }

        if out.isEmpty {
            out.append(Suggestion(kind: .nothing, project: nil,
                                  title: active.isEmpty ? "Activate a project" : "Nothing fits right now",
                                  detail: active.isEmpty ? "Pick up to two projects in the Projects tab." : "Try more time or change place.",
                                  reason: "", score: 0, topCue: "fit"))
        }
        return out.sorted { $0.score > $1.score }
    }

    private static func reason(_ cue: String, task: Candidate, cues: Cues) -> String {
        let p = task.project
        switch cue {
        case "ci": return "\(p.name)'s build is red; a quick, clear fix"
        case "gradient":
            if let next = p.milestone.next { return "\(p.name) is close to \"\(next.title)\"" }
            return "\(p.name) is nearly done"
        case "stale": return "\(p.name) hasn't moved in \(p.daysSinceProgress) days"
        case "energy": return "Matches your \(cues.energy.label.lowercased()) energy"
        default: return "Fits in your \(cues.minutes) minutes"
        }
    }

    /// Skipped: trust that cue a bit less. Done: a bit more.
    static func learn(from s: Suggestion, done: Bool) {
        var w = weights
        let current = w[s.topCue] ?? 1
        w[s.topCue] = done ? min(2.0, current * 1.04) : max(0.3, current * 0.94)
        weights = w
    }
}
