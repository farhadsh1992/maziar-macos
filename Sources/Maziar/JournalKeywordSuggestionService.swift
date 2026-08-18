import Foundation

/// Suggests journals to track based on research keywords (e.g. "computer vision, medical
/// imaging"), using the AI's own knowledge (grounded with live web search where the provider
/// supports it) rather than scraping a specific listing page.
@MainActor
enum JournalKeywordSuggestionService {
    private struct SuggestedItem: Decodable {
        var name: String
        var url: String?
    }

    static func suggestCandidates(
        forKeywords keywords: String, excluding existingNames: [String], settings: AISettings
    ) async throws -> [JournalCandidate] {
        let trimmed = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Maziar", code: 60, userInfo: [
                NSLocalizedDescriptionKey: "Enter one or more keywords, e.g. \"computer vision, medical imaging\"."
            ])
        }

        let provider = settings.effectiveJournalProvider
        let model = settings.effectiveJournalModel()
        let existingList = existingNames.isEmpty ? "none yet" : existingNames.joined(separator: ", ")
        let systemPrompt = """
        You are helping a researcher find relevant academic journals to submit papers to, based on \
        these research keywords: "\(trimmed)".
        Suggest well-known, relevant journals (by their common short name/acronym), spanning both \
        top-tier and reasonably well-known venues in this area. Skip anything already in this \
        tracked list: \(existingList).

        Respond with ONLY a JSON array and nothing else — no prose, no markdown code fences — \
        matching exactly this shape:
        [{"name": string, "url": string or null}, ...]
        Include the journal's official website URL only when you're confident of it, otherwise \
        null. Suggest at most 15, most relevant first.
        """

        let webSearch = JournalInfoService.supportsLiveWebSearch(provider)
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "Suggest journals now.")],
            webSearch: webSearch,
            modelOverride: model
        )
        guard let items = JSONExtraction.decodeArray([SuggestedItem].self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 61, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }

        var seen = Set(existingNames.map { $0.lowercased() })
        var candidates: [JournalCandidate] = []
        for item in items {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let urlString = item.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(JournalCandidate(name: name, websiteURLString: (urlString?.isEmpty ?? true) ? nil : urlString))
        }
        return candidates
    }
}
