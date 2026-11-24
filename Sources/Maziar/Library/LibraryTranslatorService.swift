import Foundation

/// Plain text-in, translated-text-out — the "Translator" side of the paper reader companion
/// window. Uses the AI Assistant's current provider, same reasoning as `LibraryMetadataService`:
/// translation doesn't need web-search grounding or its own per-feature override.
@MainActor
enum LibraryTranslatorService {
    static func translate(_ text: String, to targetLanguage: String, settings: AISettings) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let systemPrompt = """
        Translate the user's text into \(targetLanguage). Respond with ONLY the translation — no \
        commentary, no notes, no repeating the original, no markdown fences. Preserve paragraph \
        breaks. If the text is already in \(targetLanguage), respond with it unchanged.
        """

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        return try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: trimmed)],
            modelOverride: model
        )
    }
}
