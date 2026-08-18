import Foundation

struct ProviderTokenTotals: Codable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
}

/// Running token totals per provider, recorded centrally by `AIClient.send` (every call site —
/// AI Assistant chat, prompt tasks, conference lookups — gets tracked automatically). Read from
/// Settings \u{2192} AI \u{2192} Usage & Cost to show a running estimate of what you've spent.
@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()

    @Published private(set) var totals: [AIProviderKind: ProviderTokenTotals] {
        didSet { persist() }
    }

    private static let key = "maziar.ai.tokenUsage"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: ProviderTokenTotals].self, from: data) {
            var loaded: [AIProviderKind: ProviderTokenTotals] = [:]
            for (rawKey, value) in decoded {
                if let provider = AIProviderKind(rawValue: rawKey) { loaded[provider] = value }
            }
            totals = loaded
        } else {
            totals = [:]
        }
    }

    func record(provider: AIProviderKind, promptTokens: Int, completionTokens: Int) {
        var current = totals[provider] ?? ProviderTokenTotals()
        current.promptTokens += promptTokens
        current.completionTokens += completionTokens
        totals[provider] = current
    }

    func reset(_ provider: AIProviderKind) {
        totals[provider] = nil
    }

    func resetAll() {
        totals = [:]
    }

    func estimatedCost(for provider: AIProviderKind, settings: AISettings) -> Double {
        let usage = totals[provider] ?? ProviderTokenTotals()
        let inputCost = Double(usage.promptTokens) / 1_000_000 * settings.inputPrice(for: provider)
        let outputCost = Double(usage.completionTokens) / 1_000_000 * settings.outputPrice(for: provider)
        return inputCost + outputCost
    }

    private func persist() {
        var dict: [String: ProviderTokenTotals] = [:]
        for (provider, value) in totals { dict[provider.rawValue] = value }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
