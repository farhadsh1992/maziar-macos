import Foundation

/// Chat for the paper reader companion window — free-form Q&A about one specific paper, seeded
/// with its title/authors/abstract as context so "what's the main contribution here?" works
/// without the model needing the full PDF text. Same shape as ConferenceChatViewModel/
/// JournalChatViewModel (plain message list, no persistence — this is a scratch conversation, not
/// tracked data).
@MainActor
final class PaperChatViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let role: AIChatMessage.Role
        var content: String
    }

    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?

    func send(about entry: LibraryEntry, settings: AISettings) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil
        messages.append(Message(role: .user, content: trimmed))

        isSending = true
        defer { isSending = false }

        var systemPrompt = """
        You are a research assistant helping the user understand and discuss one specific paper. \
        Answer questions about it, explain concepts, summarize sections, and generally help them \
        engage with it. If a question needs the full text and you only have the details below, say \
        so rather than guessing.

        Paper: \(entry.title)
        """
        if let authors = entry.authors, !authors.isEmpty { systemPrompt += "\nAuthors: \(authors)" }
        if let venue = entry.venue, !venue.isEmpty { systemPrompt += "\nVenue: \(venue)" }
        if let year = entry.year, !year.isEmpty { systemPrompt += "\nYear: \(year)" }
        if let abstract = entry.abstract, !abstract.isEmpty { systemPrompt += "\nAbstract: \(abstract)" }

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let history = messages.map { AIChatMessage(role: $0.role, content: $0.content) }
        do {
            let reply = try await AIClient.send(
                provider: provider,
                settings: settings,
                systemPrompt: systemPrompt,
                history: history,
                modelOverride: model
            )
            messages.append(Message(role: .assistant, content: reply))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        messages.removeAll()
        errorMessage = nil
    }
}
