import Foundation

/// Fills in a library entry's title/authors/year/venue/DOI from the PDF's own first-page text
/// (extracted via PDFKit in the view), using whichever AI provider the AI Assistant is currently
/// set to — a plain text-extraction task like this doesn't need the web-search grounding or
/// per-feature provider override the Conference/Journal lookups do.
@MainActor
enum LibraryMetadataService {
    struct ExtractedMetadata: Decodable {
        var title: String?
        var authors: String?
        var year: String?
        var venue: String?
        var doi: String?
        var affiliation: String?
        var abstract: String?
    }

    enum ExtractionError: LocalizedError {
        case noText
        var errorDescription: String? {
            switch self {
            case .noText: return "Couldn't read any text from this PDF's first page (it may be a scanned image)."
            }
        }
    }

    static func extract(fromFirstPageText text: String, settings: AISettings) async throws -> ExtractedMetadata {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractionError.noText }

        let systemPrompt = """
        You extract bibliographic metadata from the first-page text of an academic paper PDF \
        (raw extracted text, so layout/line breaks may be jumbled). Determine:
        - Its title.
        - Its authors, as a single string (e.g. "Jane Smith, Alex Doe").
        - Its publication year, if stated.
        - Its venue — the journal or conference it was published in, if stated.
        - Its DOI, if stated (just the identifier, e.g. "10.1145/xxxxx", not a full URL).
        - The first listed author's affiliation — the university or company name only (e.g.
          "Stanford University", "Google DeepMind"), not the full postal address.
        - Its abstract, verbatim if it's present in the text (clean up obvious line-wrap
          artifacts, but don't paraphrase or shorten it).
        Use null for anything you can't confidently determine from the text — don't guess.

        Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
        fences — matching exactly this shape:
        {"title": string or null, "authors": string or null, "year": string or null, \
        "venue": string or null, "doi": string or null, "affiliation": string or null, \
        "abstract": string or null}
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
        guard let result = JSONExtraction.decodeObject(ExtractedMetadata.self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 71, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }
        return result
    }
}
