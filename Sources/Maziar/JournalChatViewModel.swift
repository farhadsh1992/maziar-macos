import Foundation

/// Chat for the Journals page — free-form Q&A about the tracked list (with a compact summary of
/// every journal given as context), grounded with web search where the provider supports one.
/// Doesn't attempt to have the model write updates back itself — instead, a lightweight
/// "update <name>" command is matched in Swift and hands off to the same `JournalInfoService`
/// flow the Update button already uses, so "chat to trigger an update" is real, not simulated.
@MainActor
final class JournalChatViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let role: AIChatMessage.Role
        var content: String
    }

    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?

    private let systemPromptBase = """
    You are a helpful assistant for a researcher's tracked academic-journal list, embedded in a \
    macOS app. You can answer questions about the journals already tracked (using the summary \
    given below), look up journals that aren't tracked yet, compare typical review/publication \
    turnaround, explain rankings/impact factors, and generally help with journal-related \
    questions. Journals are rolling-submission, not fixed-deadline like conferences — don't imply \
    they have a submission deadline unless the journal specifically has an active special issue. \
    Search the web if you're able to. You cannot edit the tracked list yourself — if the user \
    wants a tracked journal's stored info refreshed, tell them to type "update <journal name>" \
    and the app will refresh it directly; don't claim to have updated anything yourself.
    """

    /// Returns the matching journal to update if the message is an "update"/"refresh" command, so
    /// the caller can trigger the real update flow instead of sending this to the AI.
    func detectUpdateCommand(_ text: String, journals: [JournalEntry]) -> JournalEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["update ", "refresh "]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return journals.first {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }
    }

    func send(settings: AISettings, journals: [JournalEntry], onTriggerUpdate: (JournalEntry) -> Void) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil
        messages.append(Message(role: .user, content: trimmed))

        if let matched = detectUpdateCommand(trimmed, journals: journals) {
            messages.append(Message(
                role: .assistant,
                content: "Updating \u{201c}\(matched.name)\u{201d} now \u{2014} watch its card on the page for progress."
            ))
            onTriggerUpdate(matched)
            return
        }

        isSending = true
        defer { isSending = false }

        var systemPrompt = systemPromptBase
        systemPrompt += "\n\nCurrently tracked:\n\(journalSummary(journals))"

        let provider = settings.effectiveJournalProvider
        let model = settings.effectiveJournalModel()
        let webSearch = JournalInfoService.supportsLiveWebSearch(provider)
        let history = messages.map { AIChatMessage(role: $0.role, content: $0.content) }
        do {
            let reply = try await AIClient.send(
                provider: provider,
                settings: settings,
                systemPrompt: systemPrompt,
                history: history,
                webSearch: webSearch,
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

    private func journalSummary(_ journals: [JournalEntry]) -> String {
        guard !journals.isEmpty else { return "(none tracked yet)" }
        return journals.map { entry in
            let rankText = entry.rank ?? "unknown"
            let reviewText = entry.reviewTime ?? "unknown"
            let publicationText = entry.publicationTime ?? "unknown"
            return "- \(entry.name)\(entry.fullName.map { " (\($0))" } ?? ""): rank \(rankText), review time \(reviewText), publication time \(publicationText)"
        }.joined(separator: "\n")
    }
}
