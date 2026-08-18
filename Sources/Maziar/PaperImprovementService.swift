import Foundation

/// After a rejection, reviews the paper together with whatever reviewer comments were recorded
/// and suggests concrete ways to strengthen it for resubmission. Free-form markdown output, same
/// shape as `PaperRebuttalService` but framed around improvement rather than rebuttal.
@MainActor
enum PaperImprovementService {
    static func suggestImprovements(reviewerComments: [ReviewerComment], paperText: String?, settings: AISettings) async throws -> String {
        let nonEmptyComments = reviewerComments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard paperText != nil || !nonEmptyComments.isEmpty else {
            throw NSError(domain: "Maziar", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "Link a LaTeX project or add reviewer comments first — there's nothing to review yet."
            ])
        }

        var systemPrompt = """
        A paper was rejected. Review it (and the reviewers' comments, if given below) and give \
        concrete, actionable suggestions for strengthening it before resubmitting elsewhere — \
        methodology gaps, missing experiments/baselines, unclear writing or positioning versus \
        related work, overclaiming, etc. Organize suggestions by theme, most important first. Be \
        specific: point to what's actually weak, not generic advice like "add more experiments." \
        If reviewer comments are given, make sure every recurring concern is addressed by at \
        least one suggestion.
        """
        if let paperText, !paperText.isEmpty {
            systemPrompt += "\n\nThe paper's LaTeX source:\n```latex\n\(paperText.prefix(12000))\n```"
        }

        let commentsBlock = nonEmptyComments
            .map { "### \($0.label)\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        let userMessage = commentsBlock.isEmpty
            ? "No reviewer comments were recorded — review the paper on its own and suggest improvements."
            : commentsBlock

        return try await AIClient.send(
            provider: settings.activeProvider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userMessage)]
        )
    }
}
