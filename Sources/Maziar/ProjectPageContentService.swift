import Foundation

/// Writes a short, polished project-page description from the paper's LaTeX source via AI —
/// used by the Code Page generator instead of (or in addition to) mechanically extracting
/// `\begin{abstract}`. Plain text response, no JSON needed.
@MainActor
enum ProjectPageContentService {
    static func generateDescription(title: String, paperText: String, settings: AISettings) async throws -> String {
        let provider = settings.effectiveCodePageProvider
        let model = settings.effectiveCodePageModel()
        let systemPrompt = """
        You are writing the short description paragraph for an academic paper's project webpage \
        (the kind linked from a paper's code release), titled "\(title)". Write one concise, \
        clear paragraph (3\u{2013}5 sentences) summarizing what the paper does and why it matters, \
        in plain language suitable for a project homepage — not the formal academic abstract \
        verbatim, but not marketing fluff either. Base it only on the paper content below; don't \
        invent results. Respond with ONLY the paragraph text, no heading, no markdown.
        """
        return try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "```latex\n\(paperText.prefix(16000))\n```")],
            modelOverride: model
        )
    }
}
