import Foundation

/// Given a page that lists many journals (e.g. a publisher's journal directory), reads its links
/// and asks the AI to identify which of them are actual individual journals, so they can be added
/// to the tracked list in bulk instead of typing each one in by hand.
@MainActor
enum JournalListImportService {
    private struct ExtractedItem: Decodable {
        var name: String
        var url: String?
    }

    static func importCandidates(fromListingURL urlString: String, settings: AISettings) async throws -> [JournalCandidate] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw NSError(domain: "Maziar", code: 50, userInfo: [NSLocalizedDescriptionKey: "Enter a valid website URL, e.g. https://ieeexplore.ieee.org/browse/periodicals/title"])
        }

        let links = await WebPageFetcher.fetchLinks(from: url, maxLinks: 400)
        guard !links.isEmpty else {
            throw NSError(domain: "Maziar", code: 51, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't fetch that page or find any links on it. It may require JavaScript to render its content, which this import can't read."
            ])
        }

        let linkList = links.map { "- \($0.text) \u{2014} \($0.href)" }.joined(separator: "\n")
        let systemPrompt = """
        You are helping catalog academic journals from a listing webpage. Below is a list of \
        links (visible text and URL) extracted from the page at \(trimmed). Identify which of \
        these links point to actual individual academic/research journals — NOT navigation, \
        sponsors, social media, "About/Contact/Login" pages, or unrelated content. For each one \
        that qualifies, give its short journal name (prefer the common acronym people use, e.g. \
        "IEEE Transactions on Pattern Analysis and Machine Intelligence" \u{2192} "TPAMI" where one \
        exists, otherwise a short form of the full title) and its URL.

        Respond with ONLY a JSON array and nothing else — no prose, no markdown code fences \u{2014} \
        matching exactly this shape:
        [{"name": string, "url": string}, ...]
        Omit anything that isn't really a journal. If nothing qualifies, respond with [].
        Don't list the same journal twice even if it appears under multiple links.
        """

        let provider = settings.effectiveJournalProvider
        let model = settings.effectiveJournalModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: linkList)],
            modelOverride: model
        )
        guard let items = JSONExtraction.decodeArray([ExtractedItem].self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 52, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }

        return dedupedCandidates(from: items)
    }

    private static func dedupedCandidates(from items: [ExtractedItem]) -> [JournalCandidate] {
        var seen = Set<String>()
        var candidates: [JournalCandidate] = []
        for item in items {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let websiteURLString = item.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(JournalCandidate(name: name, websiteURLString: (websiteURLString?.isEmpty ?? true) ? nil : websiteURLString))
        }
        return candidates
    }
}
