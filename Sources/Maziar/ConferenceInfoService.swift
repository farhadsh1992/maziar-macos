import Foundation

/// Looks up a tracked conference's deadlines/links using the currently selected AI provider,
/// grounding the answer with a live web search where the provider supports one (Claude, Gemini;
/// best-effort on OpenAI; DeepSeek/Kimi fall back to the model's own training-data knowledge).
@MainActor
enum ConferenceInfoService {
    private struct UpdateResult: Decodable {
        struct DeadlineJSON: Decodable {
            var label: String
            var date: String?
            var raw: String?
        }
        var authorGuideURL: String?
        var templateURL: String?
        var notes: String?
        var pageLimit: String?
        var columnFormat: String?
        var rank: String?
        var deadlines: [DeadlineJSON]
    }

    /// True for providers whose API exposes a server-side web-search tool we've wired up —
    /// used to decide whether to request `webSearch` and to warn the user when it's unavailable.
    static func supportsLiveWebSearch(_ provider: AIProviderKind) -> Bool {
        provider == .claude || provider == .gemini
    }

    static func update(_ conference: ConferenceEntry, settings: AISettings, helperWebsites: [String] = []) async -> ConferenceEntry {
        var entry = conference
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let todayString = ISO8601DateFormatter().string(from: Date()).prefix(10)

        let conferenceIdentity = conference.fullName.map { "\"\(conference.name)\" (\($0))" } ?? "\"\(conference.name)\""
        var systemPrompt = """
        You are a research-conference deadline lookup assistant embedded in a macOS app. Today's \
        date is \(todayString). Find the OFFICIAL website for the academic conference \
        \(conferenceIdentity) — search the web if you're able to, but if the user's message below \
        already includes fetched content from the conference's own site, read the answer directly \
        from that instead of searching. From whatever source, determine:
        - Its paper/abstract submission deadline(s) for \(currentYear) and \(currentYear + 1) \
        (note clearly if a future year isn't announced yet — omit it rather than guessing).
        - Any other deadlines worth surfacing (e.g. camera-ready, notification date).
        - A couple of relevant PAST deadlines if you can find them, for context.
        - The URL of its author/submission guide or "call for papers" page.
        - The URL of its official LaTeX template/format (a direct link to a .zip/.tex template, \
        or the page that hosts it).
        - Its page limit for submissions, in whatever units it's stated (e.g. "8 pages + \
        unlimited references") — null if you don't know.
        - Whether it uses single-column or double-column formatting — null if unstated/unclear.
        - Its most commonly cited ranking, if it has a well-known one (e.g. CORE "A*"/"A"/"B"/"C", \
        CCF "A"/"B"/"C", a journal quartile like "Q1") — null if it doesn't have one or you're \
        not confident.

        Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
        fences — matching exactly this shape:
        {"authorGuideURL": string or null, "templateURL": string or null, "notes": string or null, \
        "pageLimit": string or null, "columnFormat": string or null, "rank": string or null, \
        "deadlines": [{"label": string, "date": "YYYY-MM-DD" or null, "raw": string or null}]}
        Use "date" only when you're confident of the exact day; otherwise leave it null and put \
        your best description (e.g. "mid-March 2027, exact date TBA") in "raw".
        """
        if !helperWebsites.isEmpty {
            systemPrompt += """
            \n
            If you need to search the web, these reference sites are good starting points for \
            conference metadata (rankings, deadline listings, calls for papers) — check them in \
            addition to the conference's own site, not instead of it: \(helperWebsites.joined(separator: ", ")).
            """
        }

        let provider = settings.effectiveConferenceProvider
        let model = settings.effectiveConferenceModel()

        // If the user already supplied this/next year's site, fetch its content ourselves and
        // hand it straight to the model — faster and more reliable than the model's own search
        // tool, which is what was timing out. Search stays on as a fallback for anything the
        // fetched pages don't cover (e.g. next year's page not published yet).
        let thisYearURL = entry.thisYearWebsiteURL
        let thisYearURLString = entry.thisYearWebsiteURLString
        let nextYearURL = entry.nextYearWebsiteURL
        let nextYearURLString = entry.nextYearWebsiteURLString
        async let thisYearFetch = fetchedSiteBlock(thisYearURL, label: "this year", urlString: thisYearURLString)
        async let nextYearFetch = fetchedSiteBlock(nextYearURL, label: "next year", urlString: nextYearURLString)
        let (thisYearBlock, nextYearBlock) = await (thisYearFetch, nextYearFetch)
        let fetchedBlocks = [thisYearBlock, nextYearBlock].compactMap { $0 }
        let bothSitesFetched = thisYearURL != nil && nextYearURL != nil
            && thisYearBlock?.hasFetchedContent == true && nextYearBlock?.hasFetchedContent == true

        let userMessage: String
        if fetchedBlocks.isEmpty {
            userMessage = "Look up \(conferenceIdentity) now and return the JSON."
        } else {
            let blocks = fetchedBlocks.map(\.text).joined(separator: "\n\n---\n\n")
            userMessage = "\(blocks)\n\nNow return the JSON for \"\(conference.name)\"."
        }

        // Skip the (slower) search tool only when we already fetched both years' pages directly.
        let webSearch = supportsLiveWebSearch(provider) && !bothSitesFetched
        do {
            let reply = try await AIClient.send(
                provider: provider,
                settings: settings,
                systemPrompt: systemPrompt,
                history: [AIChatMessage(role: .user, content: userMessage)],
                webSearch: webSearch,
                modelOverride: model
            )
            guard let result = JSONExtraction.decodeObject(UpdateResult.self, from: reply) else {
                let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                entry.lastUpdateError = "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
                return entry
            }
            entry.authorGuideURLString = result.authorGuideURL ?? entry.authorGuideURLString
            entry.templateURLString = result.templateURL ?? entry.templateURLString
            entry.notes = result.notes
            entry.pageLimit = result.pageLimit
            entry.columnFormat = result.columnFormat
            entry.rank = result.rank
            entry.deadlines = result.deadlines.map {
                ConferenceDeadlineInfo(label: $0.label, dateString: $0.date, rawText: $0.raw)
            }
            entry.lastUpdated = Date()
            entry.lastUpdateError = nil
        } catch {
            entry.lastUpdateError = error.localizedDescription
        }
        return entry
    }

    private struct FetchedSiteBlock {
        var text: String
        var hasFetchedContent: Bool
    }

    /// Fetches a conference's own site (best-effort) and formats it as a block for the prompt;
    /// still returns a block (naming the URL) even on fetch failure, so the model at least knows
    /// the URL exists and can search for it itself as a fallback.
    private static func fetchedSiteBlock(_ url: URL?, label: String, urlString: String?) async -> FetchedSiteBlock? {
        guard let url, let urlString else { return nil }
        if let text = await WebPageFetcher.fetchPlainText(from: url) {
            return FetchedSiteBlock(
                text: "Official website (\(label), \(urlString)) — fetched content:\n\(text)",
                hasFetchedContent: true
            )
        }
        return FetchedSiteBlock(
            text: "Official website (\(label)): \(urlString) — couldn't fetch its content automatically; search for it if you can.",
            hasFetchedContent: false
        )
    }

}
