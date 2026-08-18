import Foundation

/// Chat for the Conferences page — free-form Q&A about the tracked list (with a compact summary
/// of every conference given as context, so "which of mine has the closest deadline?" works),
/// grounded with web search where the provider supports one. Doesn't attempt to have the model
/// write updates back itself (fragile tool-calling for little gain) — instead, a lightweight
/// "update <name>" command is matched in Swift and hands off to the same `ConferenceInfoService`
/// flow the Update button already uses, so "chat to trigger an update" is real, not simulated.
@MainActor
final class ConferenceChatViewModel: ObservableObject {
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
    You are a helpful assistant for a researcher's tracked academic-conference list, embedded in \
    a macOS app. You can answer questions about the conferences already tracked (using the \
    summary given below), look up conferences that aren't tracked yet, compare deadlines, explain \
    rankings, and generally help with conference-related questions. Search the web if you're able \
    to. You cannot edit the tracked list yourself — if the user wants a tracked conference's \
    stored info refreshed, tell them to type "update <conference name>" and the app will refresh \
    it directly; don't claim to have updated anything yourself.
    """

    /// Returns the matching conference to update if the message is an "update"/"refresh" command,
    /// so the caller can trigger the real update flow instead of sending this to the AI.
    func detectUpdateCommand(_ text: String, conferences: [ConferenceEntry]) -> ConferenceEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["update ", "refresh "]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return conferences.first {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }
    }

    func send(settings: AISettings, conferences: [ConferenceEntry], onTriggerUpdate: (ConferenceEntry) -> Void) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil
        messages.append(Message(role: .user, content: trimmed))

        if let matched = detectUpdateCommand(trimmed, conferences: conferences) {
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
        systemPrompt += "\n\nCurrently tracked:\n\(conferenceSummary(conferences))"

        let provider = settings.effectiveConferenceProvider
        let model = settings.effectiveConferenceModel()
        let webSearch = ConferenceInfoService.supportsLiveWebSearch(provider)
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

    private func conferenceSummary(_ conferences: [ConferenceEntry]) -> String {
        guard !conferences.isEmpty else { return "(none tracked yet)" }
        return conferences.map { entry in
            let deadlineText: String
            if let next = entry.nextDeadline {
                let dateText = next.date?.formatted(date: .abbreviated, time: .omitted) ?? (next.rawText ?? "TBA")
                deadlineText = "\(next.label): \(dateText)"
            } else {
                deadlineText = "no upcoming deadline on file"
            }
            let rankText = entry.rank ?? "unknown"
            return "- \(entry.name)\(entry.fullName.map { " (\($0))" } ?? ""): rank \(rankText), next deadline: \(deadlineText)"
        }.joined(separator: "\n")
    }
}
