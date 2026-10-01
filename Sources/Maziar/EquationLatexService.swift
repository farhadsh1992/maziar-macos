import Foundation

/// Turns a cropped screenshot of a rendered equation into LaTeX source, for the Reader window's
/// right-click "Copy as LaTeX". The PDF itself has no embedded LaTeX to recover (it was compiled
/// away into glyphs/paths), so this asks a vision-capable AI model to transcribe the image back
/// into markup — reusing `AIClient`'s existing multimodal support (`AIChatMessage.imagesBase64`,
/// already wired for OpenAI/Anthropic/Gemini) rather than adding a new code path for it.
@MainActor
enum EquationLatexService {
    enum ExtractionError: LocalizedError {
        case emptyResponse
        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "The AI didn't return any LaTeX for this equation."
            }
        }
    }

    static func extract(imageBase64: String, settings: AISettings) async throws -> String {
        let systemPrompt = """
        You transcribe a cropped image of a single mathematical equation or formula, taken from an \
        academic paper's PDF, into its LaTeX source. Respond with ONLY the LaTeX for the equation's \
        math content itself — no $ or $$ delimiters, no \\begin{equation}/\\end{equation} wrapper, no \
        prose, no markdown code fences, no explanation. If what's shown isn't actually a formula, \
        transcribe whatever text is visible as plain LaTeX-escaped text instead of refusing.
        """
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "Transcribe this equation to LaTeX.", imagesBase64: [imageBase64])],
            modelOverride: model
        )
        var trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            trimmed = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { throw ExtractionError.emptyResponse }
        return trimmed
    }
}
