import Foundation
import UIKit

/// "Ask Claude": opens a Claude Code session on the project's repo with the
/// next step already typed in (not sent). Also copies the text, so you can
/// paste it into a regular chat instead.
enum ClaudeLink {
    static func prompt(for p: Project) -> String {
        var lines: [String] = []
        lines.append("Project: \(p.name)" + (p.hasRepo ? " (repo \(p.repoOwner)/\(p.repoName))" : ""))
        lines.append("Stage: \(p.milestone.title)" + (p.milestone.next.map { ". Next rung: \($0.title)" } ?? ""))
        if !p.ciSummary.isEmpty { lines.append("CI: \(p.ciSummary)") }
        if !p.ciDetail.isEmpty { lines.append(p.ciDetail) }
        if p.ciFailing {
            lines.append("Task: fix the failing CI check first. Read the failing workflow log, find the cause, fix it, and keep plugin IDs unchanged.")
        }
        if p.hasNextStep {
            lines.append("Next step: \(p.nextStepSentence)")
        }
        lines.append("Do only this step. Keep it small enough to finish in about \(p.nextMinutes) minutes, and tell me how to check it worked.")
        return lines.joined(separator: "\n")
    }

    static func url(for p: Project) -> URL? {
        var comps = URLComponents(string: "https://claude.ai/code/new")
        var items = [URLQueryItem(name: "q", value: prompt(for: p))]
        if p.hasRepo { items.append(URLQueryItem(name: "repo", value: "\(p.repoOwner)/\(p.repoName)")) }
        comps?.queryItems = items
        return comps?.url
    }

    @MainActor
    static func copy(for p: Project) {
        UIPasteboard.general.string = prompt(for: p)
    }
}
