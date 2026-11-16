import Foundation
import SwiftData

// MARK: - Enums

enum ProjectState: String, Codable, CaseIterable {
    case active, frozen, shipped
}

/// The progress ladder. CI only moves a project to `buildsGreen`;
/// the last two rungs are confirmed by you, because "shipped" means *used*.
enum Milestone: Int, Codable, CaseIterable, Comparable {
    case planned = 0
    case buildsGreen
    case loadsInDAW
    case usedInSession

    static func < (a: Milestone, b: Milestone) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .planned: return "Planned"
        case .buildsGreen: return "Builds green"
        case .loadsInDAW: return "Loads in my DAW / runs on device"
        case .usedInSession: return "Used in a real session"
        }
    }

    var short: String {
        switch self {
        case .planned: return "Planned"
        case .buildsGreen: return "Green"
        case .loadsInDAW: return "Loads"
        case .usedInSession: return "Used"
        }
    }

    var next: Milestone? { Milestone(rawValue: rawValue + 1) }
}

enum Difficulty: Int, Codable, CaseIterable, Identifiable {
    case easy = 1, medium = 2, hard = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }
}

// MARK: - Project

@Model
final class Project {
    var name: String
    var repoOwner: String
    var repoName: String
    var stateRaw: String
    var milestoneRaw: Int
    var whyThisOne: String
    var notes: String

    // Next step, written as an if-then plan.
    var nextIf: String
    var nextThen: String
    var nextMinutes: Int
    var nextDifficultyRaw: Int
    var nextNeedsMac: Bool

    var createdAt: Date
    var activatedAt: Date?
    var lastProgressAt: Date

    // CI snapshot from GitHub Actions.
    var ciSummary: String
    var ciDetail: String
    var ciFailing: Bool
    var ciURL: String
    var ciCheckedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ProgressLog.project)
    var logs: [ProgressLog] = []

    init(name: String, repoOwner: String = "", repoName: String = "", notes: String = "") {
        self.name = name
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.stateRaw = ProjectState.frozen.rawValue
        self.milestoneRaw = Milestone.planned.rawValue
        self.whyThisOne = ""
        self.notes = notes
        self.nextIf = ""
        self.nextThen = ""
        self.nextMinutes = 45
        self.nextDifficultyRaw = Difficulty.medium.rawValue
        self.nextNeedsMac = true
        self.createdAt = .now
        self.activatedAt = nil
        self.lastProgressAt = .now
        self.ciSummary = ""
        self.ciDetail = ""
        self.ciFailing = false
        self.ciURL = ""
        self.ciCheckedAt = nil
    }

    var state: ProjectState {
        get { ProjectState(rawValue: stateRaw) ?? .frozen }
        set { stateRaw = newValue.rawValue }
    }

    var milestone: Milestone {
        get { Milestone(rawValue: milestoneRaw) ?? .planned }
        set { milestoneRaw = newValue.rawValue }
    }

    var nextDifficulty: Difficulty {
        get { Difficulty(rawValue: nextDifficultyRaw) ?? .medium }
        set { nextDifficultyRaw = newValue.rawValue }
    }

    var hasRepo: Bool { !repoOwner.isEmpty && !repoName.isEmpty }

    var hasNextStep: Bool { !nextThen.trimmingCharacters(in: .whitespaces).isEmpty }

    var nextStepSentence: String {
        let cue = nextIf.trimmingCharacters(in: .whitespaces)
        let act = nextThen.trimmingCharacters(in: .whitespaces)
        if cue.isEmpty { return act }
        return "When \(cue), I will \(act)."
    }

    var daysSinceProgress: Int {
        Calendar.current.dateComponents([.day], from: lastProgressAt, to: .now).day ?? 0
    }

    var sortedLogs: [ProgressLog] { logs.sorted { $0.date > $1.date } }

    func log(_ note: String) {
        let entry = ProgressLog(note: note)
        logs.append(entry)
        lastProgressAt = .now
    }

    /// Apply the newest GitHub Actions result for each workflow.
    func apply(_ runs: [WorkflowStatus]) {
        ciCheckedAt = .now
        guard !runs.isEmpty else {
            ciSummary = "No CI runs yet"
            ciDetail = ""
            ciFailing = false
            return
        }
        let completed = runs.filter { $0.status == "completed" }
        let passed = completed.filter { $0.conclusion == "success" }.count
        let failed = completed.contains { ["failure", "timed_out", "startup_failure"].contains($0.conclusion ?? "") }
        let running = runs.count > completed.count

        ciFailing = failed
        ciSummary = "\(passed)/\(runs.count) checks green" + (running ? " · running" : "")
        ciDetail = runs.map { "\($0.icon) \($0.name)" }.joined(separator: "\n")
        if let bad = runs.first(where: { $0.conclusion == "failure" }) {
            ciURL = bad.htmlURL
        } else {
            ciURL = runs.first?.htmlURL ?? ""
        }

        // CI is a health signal: it can only lift a project to the first rung.
        if !failed && !running && passed == runs.count && milestone == .planned {
            milestone = .buildsGreen
            log("All CI checks green, moved to \"Builds green\" automatically")
        }
    }
}

// MARK: - Logs, ideas, events

@Model
final class ProgressLog {
    var date: Date
    var note: String
    var project: Project?

    init(note: String) {
        self.date = .now
        self.note = note
    }
}

@Model
final class Idea {
    var text: String
    var plan: String
    var languageCode: String
    var createdAt: Date
    var promotedAt: Date?
    var archived: Bool

    init(text: String, plan: String, languageCode: String) {
        self.text = text
        self.plan = plan
        self.languageCode = languageCode
        self.createdAt = .now
        self.promotedAt = nil
        self.archived = false
    }

    var title: String {
        let first = text.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? text
        return String(first.prefix(60))
    }
}

/// Swaps, snoozes, promotions: anything that bends a rule gets logged.
@Model
final class EventLog {
    var date: Date
    var kind: String
    var detail: String

    init(kind: String, detail: String) {
        self.date = .now
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - CI value type

struct WorkflowStatus: Sendable {
    let name: String
    let path: String
    let status: String
    let conclusion: String?
    let htmlURL: String

    var icon: String {
        if status != "completed" { return "⏳" }
        switch conclusion {
        case "success": return "✅"
        case "failure", "timed_out", "startup_failure": return "❌"
        case "cancelled", "skipped": return "⚪️"
        default: return "•"
        }
    }
}
