import Foundation

/// Turns a paper's LaTeX source into structured slide/poster content via AI, then hands it to
/// `PPTXBuilder` to produce a real .pptx — either a multi-slide talk deck or a single big poster
/// slide (a large custom canvas is how academic posters are normally authored in PowerPoint).
@MainActor
enum PaperDeckService {
    enum Style {
        case talk
        case poster
    }

    private struct SectionJSON: Decodable {
        var heading: String
        var bullets: [String]
    }

    static func generateDeck(title: String, paperText: String?, style: Style, settings: AISettings) async throws -> Data {
        let sections = try await generateSections(title: title, paperText: paperText, style: style, settings: settings)
        switch style {
        case .talk:
            return try PPTXBuilder.buildTalkDeck(title: title, sections: sections)
        case .poster:
            return try PPTXBuilder.buildPoster(title: title, sections: sections)
        }
    }

    private static func generateSections(
        title: String, paperText: String?, style: Style, settings: AISettings
    ) async throws -> [PPTXBuilder.Section] {
        guard let paperText, !paperText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Maziar", code: 60, userInfo: [
                NSLocalizedDescriptionKey: "Link a LaTeX project with content first — there's nothing to summarize yet."
            ])
        }

        let styleHint = style == .talk
            ? "Aim for 5\u{2013}8 slides, each with a short heading and 3\u{2013}5 brief bullets suitable for a spoken conference talk."
            : "Aim for 4\u{2013}6 sections (e.g. Introduction, Method, Results, Conclusion), each with a short heading and 3\u{2013}5 brief bullets suitable for a printed poster — keep bullets short since poster text needs to be readable from a distance."

        let systemPrompt = """
        You are turning an academic paper's LaTeX source into \(style == .talk ? "presentation slides" : "poster sections") \
        titled "\(title)". \(styleHint)
        Base the content only on what's actually in the paper below — don't invent results.

        Respond with ONLY a JSON array and nothing else — no prose, no markdown code fences — \
        matching exactly this shape:
        [{"heading": string, "bullets": [string, ...]}, ...]
        """

        let provider = settings.effectiveDeckProvider
        let model = settings.effectiveDeckModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "```latex\n\(paperText.prefix(16000))\n```")],
            modelOverride: model
        )
        guard let items = JSONExtraction.decodeArray([SectionJSON].self, from: reply), !items.isEmpty else {
            let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw NSError(domain: "Maziar", code: 61, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't parse \(provider.displayName)'s response as JSON. Raw reply: \(preview)"
            ])
        }
        return items.map { PPTXBuilder.Section(heading: $0.heading, bullets: $0.bullets) }
    }
}
