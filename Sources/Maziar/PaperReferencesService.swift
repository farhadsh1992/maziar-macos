import Foundation

/// AI-based fallback for splitting a paper's bibliography into individual entries — only used
/// when `BibliographySplitter`'s local, deterministic `[1]`-style split finds nothing (an
/// unnumbered author-year bibliography, e.g. APA/Chicago style). Also finds a downloadable PDF URL
/// for one reference, same "AI + live web search instead of scraping Scholar directly" pattern as
/// `PaperScholarLookupService`, since Scholar has no public API and blocks automated scraping.
@MainActor
enum PaperReferencesService {
    struct DownloadLookup: Decodable {
        var url: String?
    }

    enum ExtractionError: LocalizedError {
        case noText
        var errorDescription: String? {
            switch self {
            case .noText: return "Couldn't read any text from this PDF (it may be a scanned image)."
            }
        }
    }

    enum LookupError: LocalizedError {
        case notFound
        var errorDescription: String? {
            switch self {
            case .notFound: return "Couldn't find a freely downloadable PDF for this reference."
            }
        }
    }

    /// Returns each bibliography entry as its own plain string, verbatim — deliberately a flat
    /// array of strings rather than structured objects (title/authors/year separated out): a real
    /// paper's reference list can run 50-100+ entries, and asking a model to echo that many back
    /// as multi-field JSON objects makes it far more likely the response gets cut off before the
    /// closing bracket, corrupting the whole result. A plain string array is the smallest, most
    /// robust shape for "just copy out the list."
    static func extractReferences(fromDocumentText text: String, settings: AISettings) async throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractionError.noText }

        let systemPrompt = """
        You are given the raw extracted text of an academic paper (layout/line breaks may be \
        jumbled since it comes straight from a PDF, not the original document). Find its \
        References/Bibliography section and return every entry in it verbatim, cleaned only of \
        obvious line-wrap artifacts (join wrapped lines back into one line per entry) — don't \
        paraphrase, shorten, or reformat the citation itself. If there is no References/
        Bibliography section in the text, return an empty array.

        Respond with ONLY a single JSON array of strings and nothing else — no prose, no markdown \
        code fences — e.g. ["First reference exactly as it appears...", "Second reference..."]
        """

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: trimmed)],
            modelOverride: model
        )
        guard let result = JSONExtraction.decodeArray([String].self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 74, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }
        return result
    }

    /// Searches for a direct, freely-downloadable PDF URL for one reference (e.g. an arXiv,
    /// OpenReview, ACL Anthology, or author's-page copy) — deliberately asked to reject paywalled
    /// or landing-page links rather than return something `downloadAndAddPaper` would just fail on
    /// with a less useful error, since it can check the magic bytes but can't tell "paywall" from
    /// "wrong content" on its own.
    static func findDownloadURL(for reference: String, settings: AISettings) async throws -> String {
        let trimmedQuery = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw LookupError.notFound }

        let systemPrompt = """
        You are a bibliographic lookup assistant embedded in a macOS app. Search the web for a \
        direct, freely-downloadable PDF of the academic paper cited below — e.g. an arXiv \
        abstract/PDF page, OpenReview, ACL Anthology, a preprint server, or the author's own \
        personal/lab page. Do NOT return a DOI landing page, a publisher paywall page, a search \
        results page, or anything you're not confident is either a direct PDF link or a page whose \
        single obvious PDF download link you're including instead. If you can't find one you're \
        confident is freely downloadable, return null rather than guessing.

        Reference: \(trimmedQuery)

        Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
        fences — matching exactly this shape: {"url": string or null}
        """

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let webSearch = provider == .claude || provider == .gemini
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "Find a downloadable PDF for this reference now and return the JSON.")],
            webSearch: webSearch,
            modelOverride: model
        )
        guard let result = JSONExtraction.decodeObject(DownloadLookup.self, from: reply),
              let url = result.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw LookupError.notFound
        }
        return url
    }
}
