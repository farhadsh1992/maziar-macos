import Foundation

/// Given a page that lists many conferences (e.g. https://www.thecvf.com), reads its links and
/// asks the AI to identify which of them are actual individual conferences, so they can be added
/// to the tracked list in bulk instead of typing each one in by hand.
@MainActor
enum ConferenceListImportService {
    private struct ExtractedItem: Decodable {
        var name: String
        var url: String?
    }

    static func importCandidates(fromListingURL urlString: String, settings: AISettings) async throws -> [ConferenceCandidate] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw NSError(domain: "Maziar", code: 20, userInfo: [NSLocalizedDescriptionKey: "Enter a valid website URL, e.g. https://www.thecvf.com"])
        }

        let links = await WebPageFetcher.fetchLinks(from: url, maxLinks: 400)
        guard !links.isEmpty else {
            throw NSError(domain: "Maziar", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't fetch that page or find any links on it. It may require JavaScript to render its content, which this import can't read."
            ])
        }

        let linkList = links.map { "- \($0.text) \u{2014} \($0.href)" }.joined(separator: "\n")
        let systemPrompt = """
        You are helping catalog academic conferences from a listing webpage. Below is a list of \
        links (visible text and URL) extracted from the page at \(trimmed). Identify which of \
        these links point to actual individual academic/research conferences or workshops — NOT \
        navigation, sponsors, social media, "About/Contact/Login" pages, or unrelated content. \
        For each one that qualifies, give its short conference name (prefer the common \
        acronym people use, e.g. "CVPR 2026" \u{2192} "CVPR"; drop the year) and its URL.

        Respond with ONLY a JSON array and nothing else — no prose, no markdown code fences \u{2014} \
        matching exactly this shape:
        [{"name": string, "url": string}, ...]
        Omit anything that isn't really a conference. If nothing qualifies, respond with [].
        Don't list the same conference twice even if it appears under multiple links.
        """

        let provider = settings.effectiveConferenceProvider
        let model = settings.effectiveConferenceModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: linkList)],
            modelOverride: model
        )
        guard let items = JSONExtraction.decodeArray([ExtractedItem].self, from: reply) else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }

        return dedupedCandidates(from: items)
    }

    private static func dedupedCandidates(from items: [ExtractedItem]) -> [ConferenceCandidate] {
        var seen = Set<String>()
        var candidates: [ConferenceCandidate] = []
        for item in items {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let websiteURLString = item.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(ConferenceCandidate(name: name, websiteURLString: (websiteURLString?.isEmpty ?? true) ? nil : websiteURLString))
        }
        return candidates
    }
}
