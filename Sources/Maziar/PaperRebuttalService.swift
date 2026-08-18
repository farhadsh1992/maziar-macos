import Foundation

/// Organizes per-reviewer comments and drafts rebuttal points, grounded in the linked paper's own
/// LaTeX source when available. Free-form markdown output — no JSON needed, since this reads like
/// a chat answer rather than structured data.
@MainActor
enum PaperRebuttalService {
    static func organizeAndDraft(reviewerComments: [ReviewerComment], paperText: String?, settings: AISettings) async throws -> String {
        let nonEmpty = reviewerComments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else {
            throw NSError(domain: "Maziar", code: 50, userInfo: [NSLocalizedDescriptionKey: "Add at least one reviewer's comments first."])
        }

        var systemPrompt = """
        You are helping a researcher respond to peer review. Given the reviewers' comments below, \
        organize them by reviewer and by concern/question, then for each one draft a concise, \
        polite, and substantive rebuttal point. Where the paper's own content (given below, if \
        available) already addresses a concern, reference it specifically (e.g. "as shown in \
        Section 3..."); where it doesn't, suggest what additional experiment, clarification, or \
        wording change would address it. Write in clear markdown with a header per reviewer and, \
        under each, the concern followed immediately by its rebuttal. Don't invent results that \
        aren't in the paper — flag anything that would need new experiments instead.
        """
        if let paperText, !paperText.isEmpty {
            systemPrompt += "\n\nThe paper's LaTeX source (for reference):\n```latex\n\(paperText.prefix(12000))\n```"
        }

        let formatted = nonEmpty.map { "### \($0.label)\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")

        return try await AIClient.send(
            provider: settings.activeProvider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: formatted)]
        )
    }
}
