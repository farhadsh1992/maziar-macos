import Foundation

/// Fills in a library entry's metadata by searching the web (Google Scholar included) for its
/// title, using the currently configured AI provider — same "AI + live web search" pattern as
/// `ConferenceInfoService`/`JournalInfoService`, rather than scraping scholar.google.com directly:
/// Scholar has no public API, aggressively blocks automated scraping, and doing so would violate
/// its terms of service. Claude and Gemini both expose a server-side web-search tool that requires
/// no extra plumbing on our end; other providers fall back to their own training-data knowledge.
@MainActor
enum PaperScholarLookupService {
    struct LookupResult: Decodable {
        var title: String?
        var authors: String?
        var year: String?
        var venue: String?
        var doi: String?
        var affiliation: String?
        var abstract: String?
    }

    enum LookupError: LocalizedError {
        case emptyQuery
        var errorDescription: String? {
            switch self {
            case .emptyQuery: return "Add a title first — there's nothing to search for yet."
            }
        }
    }

    static func lookup(title: String, settings: AISettings) async throws -> LookupResult {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw LookupError.emptyQuery }

        let systemPrompt = """
        You are a bibliographic lookup assistant embedded in a macOS app. Search Google Scholar \
        and the web for the academic paper titled "\(trimmedTitle)" — search if you're able to; \
        otherwise use your best training-data knowledge. Determine:
        - Its exact, complete title (corrected if the one given is truncated, garbled from a PDF \
        extraction, or slightly off).
        - Its authors, as a single string (e.g. "Jane Smith, Alex Doe").
        - Its publication year.
        - Its venue — the journal or conference it was published in.
        - Its DOI, if you can find one (just the identifier, e.g. "10.1145/xxxxx", not a full URL).
        - The first listed author's affiliation — university or company name only.
        - A short abstract, if you can find one — leave it null rather than inventing one.
        Use null for anything you can't confidently determine — don't guess.

        Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
        fences — matching exactly this shape:
        {"title": string or null, "authors": string or null, "year": string or null, \
        "venue": string or null, "doi": string or null, "affiliation": string or null, \
        "abstract": string or null}
        """

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let webSearch = provider == .claude || provider == .gemini
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "Look up \"\(trimmedTitle)\" now and return the JSON.")],
            webSearch: webSearch,
            modelOverride: model
        )
        guard let result = JSONExtraction.decodeObject(LookupResult.self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 73, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }
        return result
    }
}
