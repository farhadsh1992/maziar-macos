import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Codable {
    case openai
    case claude
    case gemini
    case deepseek
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        }
    }

    /// OpenAI, DeepSeek, and Kimi all expose an OpenAI-compatible /chat/completions API.
    var isOpenAICompatible: Bool {
        switch self {
        case .openai, .deepseek, .kimi: return true
        case .claude, .gemini: return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.ai/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// Suggested model id shown as placeholder text — editable, since model names change often.
    var suggestedModel: String {
        switch self {
        case .openai: return "gpt-5"
        case .claude: return "claude-sonnet-5"
        case .gemini: return "gemini-2.5-pro"
        case .deepseek: return "deepseek-chat"
        case .kimi: return "kimi-k2-0711-preview"
        }
    }

    /// A short, curated list of known versions for quick-fill menus next to a model field, so
    /// "pick a version" can be a list rather than pure free text. Not exhaustive and will drift
    /// as providers ship new models — every model field stays a plain editable text field, this
    /// is just a shortcut, not the only way to set one.
    var knownModelVersions: [String] {
        switch self {
        case .openai: return ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4o", "gpt-4o-mini", "o3", "o3-mini"]
        case .claude: return ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001", "claude-fable-5"]
        case .gemini: return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi: return ["kimi-k2-0711-preview", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]
        }
    }
}

/// A saved prompt, triggered in the AI Assistant by typing "#label" — e.g. "#typo" expands to
/// the full stored prompt before it's sent. `includesPDFPages` attaches the compiled PDF's
/// pages as images to the request (needs a vision-capable model) — for tasks like checking
/// whether text inside a figure overflows, which can't be answered from the LaTeX source alone.
struct PromptTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var prompt: String
    var includesPDFPages: Bool = false
}

@MainActor
final class AISettings: ObservableObject {
    // Trivial placeholder defaults below — `init()` immediately overwrites them via
    // `loadAllFromDefaults()`. They exist only so that method call is legal (Swift requires every
    // stored property initialized before `self` is used in an instance method call), and so
    // `reloadFromDefaults()` has something well-typed to overwrite after a backup import.
    @Published var activeProvider: AIProviderKind = .claude {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: Self.activeProviderKey) }
    }
    @Published var models: [AIProviderKind: String] = [:] {
        didSet { persistModels() }
    }
    @Published var baseURLs: [AIProviderKind: String] = [:] {
        didSet { persistBaseURLs() }
    }
    @Published var promptTasks: [PromptTask] = [] {
        didSet { persistPromptTasks() }
    }
    /// Overrides for the Conference-lookup feature specifically — nil provider means "use
    /// `activeProvider`", an empty model means "use that provider's normal model". Separate from
    /// the AI Assistant's settings so a provider/model that struggles with the strict-JSON lookup
    /// task can be swapped out without changing what the chat panel uses.
    @Published var conferenceProvider: AIProviderKind? {
        didSet {
            if let conferenceProvider {
                UserDefaults.standard.set(conferenceProvider.rawValue, forKey: Self.conferenceProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.conferenceProviderKey)
            }
        }
    }
    @Published var conferenceModel: String = "" {
        didSet { UserDefaults.standard.set(conferenceModel, forKey: Self.conferenceModelKey) }
    }
    /// Same idea as the conference overrides above, but for the Journal-lookup feature.
    @Published var journalProvider: AIProviderKind? {
        didSet {
            if let journalProvider {
                UserDefaults.standard.set(journalProvider.rawValue, forKey: Self.journalProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.journalProviderKey)
            }
        }
    }
    @Published var journalModel: String = "" {
        didSet { UserDefaults.standard.set(journalModel, forKey: Self.journalModelKey) }
    }
    /// Same idea again, for the Library page's AI features (metadata extraction, translator,
    /// per-paper chat) — one override covers all three, since they're all lightweight text tasks
    /// on the same page rather than needing to be tuned independently.
    @Published var libraryProvider: AIProviderKind? {
        didSet {
            if let libraryProvider {
                UserDefaults.standard.set(libraryProvider.rawValue, forKey: Self.libraryProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.libraryProviderKey)
            }
        }
    }
    @Published var libraryModel: String = "" {
        didSet { UserDefaults.standard.set(libraryModel, forKey: Self.libraryModelKey) }
    }
    /// Same idea as the conference overrides above, but for poster/slide deck generation — a
    /// provider/model that's good at chat can still be mediocre at the "restructure this paper
    /// into slide bullets as JSON" task, so it's swappable independently right on the Poster &
    /// Slides section rather than buried in Settings.
    @Published var deckProvider: AIProviderKind? {
        didSet {
            if let deckProvider {
                UserDefaults.standard.set(deckProvider.rawValue, forKey: Self.deckProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.deckProviderKey)
            }
        }
    }
    @Published var deckModel: String = "" {
        didSet { UserDefaults.standard.set(deckModel, forKey: Self.deckModelKey) }
    }
    /// Same idea again, for the Code Page's AI-written project description.
    @Published var codePageProvider: AIProviderKind? {
        didSet {
            if let codePageProvider {
                UserDefaults.standard.set(codePageProvider.rawValue, forKey: Self.codePageProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.codePageProviderKey)
            }
        }
    }
    @Published var codePageModel: String = "" {
        didSet { UserDefaults.standard.set(codePageModel, forKey: Self.codePageModelKey) }
    }
    /// $ per 1M tokens, used to estimate cost in Settings \u{2192} AI \u{2192} Usage & Cost.
    /// These are rough defaults, not authoritative pricing — editable per provider since actual
    /// rates vary by exact model/tier and change over time.
    @Published var inputPricePerMillion: [AIProviderKind: Double] = [:] {
        didSet { Self.persistPricing(inputPricePerMillion, key: Self.inputPriceKey) }
    }
    @Published var outputPricePerMillion: [AIProviderKind: Double] = [:] {
        didSet { Self.persistPricing(outputPricePerMillion, key: Self.outputPriceKey) }
    }

    private static let activeProviderKey = "maziar.ai.activeProvider"
    private static let modelsKey = "maziar.ai.models"
    private static let baseURLsKey = "maziar.ai.baseURLs"
    private static let promptTasksKey = "maziar.ai.promptTasks"
    private static let conferenceProviderKey = "maziar.ai.conferenceProvider"
    private static let conferenceModelKey = "maziar.ai.conferenceModel"
    private static let journalProviderKey = "maziar.ai.journalProvider"
    private static let journalModelKey = "maziar.ai.journalModel"
    private static let libraryProviderKey = "maziar.ai.libraryProvider"
    private static let libraryModelKey = "maziar.ai.libraryModel"
    private static let deckProviderKey = "maziar.ai.deckProvider"
    private static let deckModelKey = "maziar.ai.deckModel"
    private static let codePageProviderKey = "maziar.ai.codePageProvider"
    private static let codePageModelKey = "maziar.ai.codePageModel"
    private static let inputPriceKey = "maziar.ai.inputPricePerMillion"
    private static let outputPriceKey = "maziar.ai.outputPricePerMillion"

    /// Rough estimates as of this build — not fetched live, and likely to drift. Always editable
    /// in Settings; treat the on-screen total as an approximation, not a bill.
    static let defaultInputPricePerMillion: [AIProviderKind: Double] = [
        .openai: 1.25, .claude: 3.0, .gemini: 1.25, .deepseek: 0.28, .kimi: 0.6
    ]
    static let defaultOutputPricePerMillion: [AIProviderKind: Double] = [
        .openai: 10.0, .claude: 15.0, .gemini: 5.0, .deepseek: 1.10, .kimi: 2.5
    ]

    static let defaultPromptTasks: [PromptTask] = [
        PromptTask(
            label: "typo",
            prompt: "Check the current file for typos and spelling mistakes (not LaTeX commands — just the prose). List each one with its approximate line number, the mistake, and the correction."
        ),
        PromptTask(
            label: "imgtext",
            prompt: "Look at the attached pages of the compiled PDF. For every figure/image, check whether any text or labels inside it overflow their boundaries, get cut off, overlap other elements, or are too small to read at this size. List each issue with the page number and figure.",
            includesPDFPages: true
        ),
        PromptTask(
            label: "bibcheck",
            prompt: "Check the bibliography: for every \\cite{...} key used in the current file, verify there's a matching, complete BibTeX entry (all fields required for its entry type — e.g. a @inproceedings needs booktitle/year/author). List any \\cite keys with no matching entry, any incomplete entries, and any .bib entries that are never cited."
        )
    ]

    init() {
        loadAllFromDefaults()
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        loadAllFromDefaults()
    }

    private func loadAllFromDefaults() {
        if let raw = UserDefaults.standard.string(forKey: Self.activeProviderKey),
           let provider = AIProviderKind(rawValue: raw) {
            activeProvider = provider
        } else {
            activeProvider = .claude
        }

        if let dict = UserDefaults.standard.dictionary(forKey: Self.modelsKey) as? [String: String] {
            var loaded: [AIProviderKind: String] = [:]
            for (key, value) in dict {
                if let provider = AIProviderKind(rawValue: key) { loaded[provider] = value }
            }
            models = loaded
        } else {
            models = [:]
        }

        if let dict = UserDefaults.standard.dictionary(forKey: Self.baseURLsKey) as? [String: String] {
            var loaded: [AIProviderKind: String] = [:]
            for (key, value) in dict {
                if let provider = AIProviderKind(rawValue: key) { loaded[provider] = value }
            }
            baseURLs = loaded
        } else {
            baseURLs = [:]
        }

        if let data = UserDefaults.standard.data(forKey: Self.promptTasksKey),
           let decoded = try? JSONDecoder().decode([PromptTask].self, from: data), !decoded.isEmpty {
            promptTasks = decoded
        } else {
            promptTasks = Self.defaultPromptTasks
        }

        if let raw = UserDefaults.standard.string(forKey: Self.conferenceProviderKey) {
            conferenceProvider = AIProviderKind(rawValue: raw)
        } else {
            conferenceProvider = nil
        }
        conferenceModel = UserDefaults.standard.string(forKey: Self.conferenceModelKey) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Self.journalProviderKey) {
            journalProvider = AIProviderKind(rawValue: raw)
        } else {
            journalProvider = nil
        }
        journalModel = UserDefaults.standard.string(forKey: Self.journalModelKey) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Self.libraryProviderKey) {
            libraryProvider = AIProviderKind(rawValue: raw)
        } else {
            libraryProvider = nil
        }
        libraryModel = UserDefaults.standard.string(forKey: Self.libraryModelKey) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Self.deckProviderKey) {
            deckProvider = AIProviderKind(rawValue: raw)
        } else {
            deckProvider = nil
        }
        deckModel = UserDefaults.standard.string(forKey: Self.deckModelKey) ?? ""

        if let raw = UserDefaults.standard.string(forKey: Self.codePageProviderKey) {
            codePageProvider = AIProviderKind(rawValue: raw)
        } else {
            codePageProvider = nil
        }
        codePageModel = UserDefaults.standard.string(forKey: Self.codePageModelKey) ?? ""

        inputPricePerMillion = Self.loadPricing(key: Self.inputPriceKey, defaults: Self.defaultInputPricePerMillion)
        outputPricePerMillion = Self.loadPricing(key: Self.outputPriceKey, defaults: Self.defaultOutputPricePerMillion)
    }

    /// Which provider the Conference-lookup feature should use right now.
    var effectiveConferenceProvider: AIProviderKind { conferenceProvider ?? activeProvider }

    /// Which provider the Journal-lookup feature should use right now.
    var effectiveJournalProvider: AIProviderKind { journalProvider ?? activeProvider }

    /// Which provider the Library page's AI features should use right now.
    var effectiveLibraryProvider: AIProviderKind { libraryProvider ?? activeProvider }

    /// Which model string the Library page's AI features should use right now.
    func effectiveLibraryModel() -> String {
        let trimmed = libraryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model(for: effectiveLibraryProvider) : trimmed
    }

    /// Which model string the Journal-lookup feature should use right now.
    func effectiveJournalModel() -> String {
        let trimmed = journalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model(for: effectiveJournalProvider) : trimmed
    }

    /// Which provider the poster/slide deck generator should use right now.
    var effectiveDeckProvider: AIProviderKind { deckProvider ?? activeProvider }

    /// Which model string the poster/slide deck generator should use right now.
    func effectiveDeckModel() -> String {
        let trimmed = deckModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model(for: effectiveDeckProvider) : trimmed
    }

    /// Which provider the Code Page's AI-written description should use right now.
    var effectiveCodePageProvider: AIProviderKind { codePageProvider ?? activeProvider }

    /// Which model string the Code Page's AI-written description should use right now.
    func effectiveCodePageModel() -> String {
        let trimmed = codePageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model(for: effectiveCodePageProvider) : trimmed
    }

    func inputPrice(for provider: AIProviderKind) -> Double {
        inputPricePerMillion[provider] ?? Self.defaultInputPricePerMillion[provider] ?? 0
    }

    func outputPrice(for provider: AIProviderKind) -> Double {
        outputPricePerMillion[provider] ?? Self.defaultOutputPricePerMillion[provider] ?? 0
    }

    func setInputPrice(_ value: Double, for provider: AIProviderKind) {
        inputPricePerMillion[provider] = value
    }

    func setOutputPrice(_ value: Double, for provider: AIProviderKind) {
        outputPricePerMillion[provider] = value
    }

    private static func loadPricing(key: String, defaults: [AIProviderKind: Double]) -> [AIProviderKind: Double] {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return defaults }
        var loaded = defaults
        for (rawKey, value) in dict {
            if let provider = AIProviderKind(rawValue: rawKey) { loaded[provider] = value }
        }
        return loaded
    }

    private static func persistPricing(_ dict: [AIProviderKind: Double], key: String) {
        var raw: [String: Double] = [:]
        for (provider, value) in dict { raw[provider.rawValue] = value }
        UserDefaults.standard.set(raw, forKey: key)
    }

    /// Which model string the Conference-lookup feature should use right now.
    func effectiveConferenceModel() -> String {
        let trimmed = conferenceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model(for: effectiveConferenceProvider) : trimmed
    }

    /// Matches a leading "#label" in `input` against a saved task, expanding it to the task's
    /// full prompt (plus anything typed after the label, appended as extra instructions).
    /// Returns the original input unchanged if it doesn't start with a known "#label".
    func expandPromptTask(_ input: String) -> (text: String, includesPDFPages: Bool) {
        guard input.hasPrefix("#") else { return (input, false) }
        let afterHash = input.dropFirst()
        let label = String(afterHash.prefix(while: { !$0.isWhitespace }))
        guard !label.isEmpty,
              let task = promptTasks.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
            return (input, false)
        }
        let remainder = afterHash.dropFirst(label.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = remainder.isEmpty ? task.prompt : "\(task.prompt)\n\nAdditional instructions: \(remainder)"
        return (combined, task.includesPDFPages)
    }

    func addPromptTask(label: String, prompt: String, includesPDFPages: Bool) {
        promptTasks.append(PromptTask(label: label, prompt: prompt, includesPDFPages: includesPDFPages))
    }

    func updatePromptTask(_ task: PromptTask) {
        guard let index = promptTasks.firstIndex(where: { $0.id == task.id }) else { return }
        promptTasks[index] = task
    }

    func removePromptTask(_ task: PromptTask) {
        promptTasks.removeAll { $0.id == task.id }
    }

    private func persistPromptTasks() {
        guard let data = try? JSONEncoder().encode(promptTasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.promptTasksKey)
    }

    func model(for provider: AIProviderKind) -> String {
        let value = models[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? provider.suggestedModel : value
    }

    func setModel(_ model: String, for provider: AIProviderKind) {
        models[provider] = model
    }

    func baseURL(for provider: AIProviderKind) -> String {
        let value = baseURLs[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? provider.defaultBaseURL : value
    }

    func setBaseURL(_ url: String, for provider: AIProviderKind) {
        baseURLs[provider] = url
    }

    func apiKey(for provider: AIProviderKind) -> String? {
        KeychainHelper.get(forKey: Self.apiKeyKeychainKey(provider))
    }

    func setAPIKey(_ key: String, for provider: AIProviderKind) {
        if key.isEmpty {
            KeychainHelper.delete(forKey: Self.apiKeyKeychainKey(provider))
        } else {
            KeychainHelper.set(key, forKey: Self.apiKeyKeychainKey(provider))
        }
    }

    func isConfigured(_ provider: AIProviderKind) -> Bool {
        !(apiKey(for: provider) ?? "").isEmpty
    }

    private static func apiKeyKeychainKey(_ provider: AIProviderKind) -> String {
        "ai-apikey:\(provider.rawValue)"
    }

    private func persistModels() {
        var dict: [String: String] = [:]
        for (provider, model) in models { dict[provider.rawValue] = model }
        UserDefaults.standard.set(dict, forKey: Self.modelsKey)
    }

    private func persistBaseURLs() {
        var dict: [String: String] = [:]
        for (provider, url) in baseURLs { dict[provider.rawValue] = url }
        UserDefaults.standard.set(dict, forKey: Self.baseURLsKey)
    }
}
