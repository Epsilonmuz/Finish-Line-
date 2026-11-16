import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a spoken idea into a 3-line plan. Uses Apple's on-device model when
/// the iPhone supports it (iPhone 15 Pro or newer with Apple Intelligence on);
/// otherwise gives a template you fill in.
enum PlanWriter {
    static var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func plan(for idea: String, languageCode: String) async -> String {
        #if canImport(FoundationModels)
        if onDeviceModelAvailable {
            let spanish = languageCode.hasPrefix("es")
            let instructions = """
            You help a solo music producer and developer park ideas instead of starting them.
            Write exactly three short lines, no extra text:
            1. Goal: what it is, in one sentence.
            2. Smallest useful version: the least that would be worth using.
            3. First step: one concrete action under 30 minutes.
            \(spanish ? "Write the plan in Spanish." : "Write the plan in English.")
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: "Idea: \(idea)")
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            } catch {
                // Fall through to the template.
            }
        }
        #endif
        return template(for: idea, languageCode: languageCode)
    }

    static func template(for idea: String, languageCode: String) -> String {
        let first = idea.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? idea
        if languageCode.hasPrefix("es") {
            return "1. Meta: \(first)\n2. Versión mínima útil: …\n3. Primer paso (menos de 30 min): …"
        }
        return "1. Goal: \(first)\n2. Smallest useful version: …\n3. First step (under 30 min): …"
    }
}
