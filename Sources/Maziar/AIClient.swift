import Foundation

struct AIChatMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
    /// Base64-encoded PNG page images (no data-URI prefix) attached to this message, e.g. for the
    /// "#imgtext" task, which needs to visually inspect the compiled PDF rather than the source.
    var imagesBase64: [String] = []
}

enum AIClientError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key set for this provider. Add one in Settings \u{2192} AI."
        case .invalidURL: return "Invalid API base URL."
        case .http(let code, let body): return "API error \(code): \(body)"
        case .decode(let reason): return "Couldn't parse the API response: \(reason)"
        }
    }
}

/// Token counts for a single request/response pair, used to keep a running cost estimate
/// (Settings \u{2192} AI \u{2192} Usage & Cost) — reported by every provider's API in a
/// differently-shaped `usage`/`usageMetadata` field.
struct AITokenUsage {
    var promptTokens: Int
    var completionTokens: Int
}

/// Generous timeout for AI requests — web-search-grounded answers (Claude/Gemini's server-side
/// search tools) and reasoning models can genuinely take well past the default 60s.
private let aiRequestTimeout: TimeInterval = 150

@MainActor
enum AIClient {
    /// - Parameter webSearch: When true, asks the provider to ground its answer with a live web
    ///   search before responding, where supported. Claude and Gemini both expose a server-side
    ///   search tool that requires no extra plumbing on our end (the provider runs the search and
    ///   folds results into its own response). OpenAI only supports this via specific
    ///   "search-preview" chat-completions models, so it's passed through best-effort — if the
    ///   configured model doesn't support it, the API will return a normal, readable error rather
    ///   than crash. DeepSeek/Kimi have no known equivalent, so this flag is a no-op for them and
    ///   they silently fall back to the model's own training-data knowledge.
    static func send(
        provider: AIProviderKind,
        settings: AISettings,
        systemPrompt: String,
        history: [AIChatMessage],
        webSearch: Bool = false,
        modelOverride: String? = nil
    ) async throws -> String {
        guard let apiKey = settings.apiKey(for: provider), !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedOverride.isEmpty ? settings.model(for: provider) : trimmedOverride
        let baseURL = settings.baseURL(for: provider)

        let result: (text: String, usage: AITokenUsage?)
        if provider.isOpenAICompatible {
            result = try await sendOpenAICompatible(
                baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: systemPrompt, history: history,
                webSearch: webSearch && provider == .openai
            )
        } else {
            switch provider {
            case .claude:
                result = try await sendAnthropic(baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: systemPrompt, history: history, webSearch: webSearch)
            case .gemini:
                result = try await sendGemini(baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: systemPrompt, history: history, webSearch: webSearch)
            case .openai, .deepseek, .kimi:
                fatalError("handled above")
            }
        }
        if let usage = result.usage {
            TokenUsageStore.shared.record(provider: provider, promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
        }
        return result.text
    }

    // MARK: - OpenAI-compatible (OpenAI, DeepSeek, Kimi)

    private static func sendOpenAICompatible(
        baseURL: String, apiKey: String, model: String, systemPrompt: String, history: [AIChatMessage],
        webSearch: Bool = false
    ) async throws -> (text: String, usage: AITokenUsage?) {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/chat/completions") else {
            throw AIClientError.invalidURL
        }
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages += history.map { message -> [String: Any] in
            guard !message.imagesBase64.isEmpty else {
                return ["role": message.role.rawValue, "content": message.content]
            }
            var parts: [[String: Any]] = [["type": "text", "text": message.content]]
            parts += message.imagesBase64.map { base64 in
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)"]]
            }
            return ["role": message.role.rawValue, "content": parts]
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        // Newer "reasoning" models (e.g. GPT-5, o-series) reject any temperature other than the
        // default (1) via Chat Completions ("Unsupported value: 'temperature' does not support
        // 0.3... Only the default (1) value is supported") — so it's simplest and most compatible
        // to just not send it and let each model use its own default, rather than trying to
        // maintain a list of which model names do/don't accept a custom value.
        if webSearch {
            // Only meaningful with a "*-search-preview" model; other models will ignore or
            // reject this field, surfaced to the caller as a normal HTTP error either way.
            body["web_search_options"] = [String: Any]()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = aiRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIClientError.decode("unexpected response shape")
        }
        var usage: AITokenUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let promptTokens = usageDict["prompt_tokens"] as? Int,
           let completionTokens = usageDict["completion_tokens"] as? Int {
            usage = AITokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
        }
        return (content, usage)
    }

    // MARK: - Anthropic (Claude)

    private static func sendAnthropic(
        baseURL: String, apiKey: String, model: String, systemPrompt: String, history: [AIChatMessage],
        webSearch: Bool = false
    ) async throws -> (text: String, usage: AITokenUsage?) {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/messages") else {
            throw AIClientError.invalidURL
        }
        let messages = history.map { message -> [String: Any] in
            guard !message.imagesBase64.isEmpty else {
                return ["role": message.role.rawValue, "content": message.content]
            }
            var parts: [[String: Any]] = [["type": "text", "text": message.content]]
            parts += message.imagesBase64.map { base64 in
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]]
            }
            return ["role": message.role.rawValue, "content": parts]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": messages
        ]
        if webSearch {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = aiRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            throw AIClientError.decode("unexpected response shape")
        }
        let text = contentBlocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIClientError.decode("no text content in response") }
        var usage: AITokenUsage?
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["input_tokens"] as? Int,
           let outputTokens = usageDict["output_tokens"] as? Int {
            usage = AITokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
        }
        return (text, usage)
    }

    // MARK: - Gemini

    private static func sendGemini(
        baseURL: String, apiKey: String, model: String, systemPrompt: String, history: [AIChatMessage],
        webSearch: Bool = false
    ) async throws -> (text: String, usage: AITokenUsage?) {
        let trimmedBase = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard var components = URLComponents(string: "\(trimmedBase)/models/\(model):generateContent") else {
            throw AIClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw AIClientError.invalidURL }

        let contents = history.map { message -> [String: Any] in
            var parts: [[String: Any]] = [["text": message.content]]
            parts += message.imagesBase64.map { base64 in
                ["inline_data": ["mime_type": "image/png", "data": base64]]
            }
            return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
        }

        var body: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemPrompt]]]
        ]
        if webSearch {
            body["tools"] = [["google_search": [String: Any]()]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = aiRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIClientError.decode("unexpected response shape")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIClientError.decode("no text content in response") }
        var usage: AITokenUsage?
        if let usageDict = json["usageMetadata"] as? [String: Any],
           let promptTokens = usageDict["promptTokenCount"] as? Int,
           let candidatesTokens = usageDict["candidatesTokenCount"] as? Int {
            usage = AITokenUsage(promptTokens: promptTokens, completionTokens: candidatesTokens)
        }
        return (text, usage)
    }

    // MARK: - Shared

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIClientError.http(http.statusCode, String(body.prefix(500)))
        }
    }
}
