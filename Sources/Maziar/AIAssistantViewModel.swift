import Foundation
import PDFKit
import AppKit

@MainActor
final class AIAssistantViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let role: AIChatMessage.Role
        var content: String
        var proposedFileContent: String?
    }

    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?

    private let systemPromptBase = """
    You are a LaTeX expert assistant embedded in a macOS LaTeX editor called Maziar. Help the \
    user understand and fix LaTeX compile errors, and answer questions about LaTeX. You can see \
    the current file's content and, when relevant, the latest compile log below. When the user \
    asks you to fix or rewrite the file, respond with the COMPLETE corrected file content in a \
    single fenced code block using ```latex ... ``` with nothing else inside that block but the \
    full file content. Keep prose explanations concise.
    """

    func send(
        settings: AISettings, currentFileName: String, currentFileContent: String, compileLog: String?,
        pdfDocument: PDFDocument? = nil
    ) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil
        // Display the raw "#label ..." text in the transcript; the API request below sends the
        // expanded prompt (and any attached PDF pages) instead, without altering what's shown.
        messages.append(Message(role: .user, content: trimmed))
        isSending = true
        defer { isSending = false }

        var systemPrompt = systemPromptBase
        systemPrompt += "\n\nCurrent file: \(currentFileName)\n```latex\n\(currentFileContent)\n```"
        if let compileLog, !compileLog.isEmpty {
            systemPrompt += "\n\nLatest compile log:\n```\n\(compileLog.suffix(4000))\n```"
        }

        let expansion = settings.expandPromptTask(trimmed)
        var history = messages.map { AIChatMessage(role: $0.role, content: $0.content) }
        if let lastIndex = history.indices.last {
            var imagesBase64: [String] = []
            if expansion.includesPDFPages, let pdfDocument {
                imagesBase64 = Self.renderPagesToBase64PNG(pdfDocument)
            }
            history[lastIndex] = AIChatMessage(role: .user, content: expansion.text, imagesBase64: imagesBase64)
        }
        do {
            let reply = try await AIClient.send(
                provider: settings.activeProvider,
                settings: settings,
                systemPrompt: systemPrompt,
                history: history
            )
            let proposed = Self.extractLatexBlock(from: reply)
            messages.append(Message(role: .assistant, content: reply, proposedFileContent: proposed))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func askAboutError(settings: AISettings, currentFileName: String, currentFileContent: String, errorLog: String) async {
        inputText = "I'm getting this LaTeX compile error — please explain what's wrong and fix it:\n\n\(errorLog.suffix(3000))"
        await send(settings: settings, currentFileName: currentFileName, currentFileContent: currentFileContent, compileLog: errorLog)
    }

    func clear() {
        messages.removeAll()
        errorMessage = nil
    }

    static func extractLatexBlock(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "```(?:latex)?\\n([\\s\\S]*?)```") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[matchRange])
    }

    /// Renders each PDF page to a base64 PNG for vision-capable models, capped at `maxPages` and
    /// downscaled to `maxDimension` on the longer side to keep request payloads reasonable.
    static func renderPagesToBase64PNG(_ document: PDFDocument, maxPages: Int = 8, maxDimension: CGFloat = 1400) -> [String] {
        var results: [String] = []
        let pageCount = min(document.pageCount, maxPages)
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = min(1.0, maxDimension / max(bounds.width, bounds.height))
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let tiffData = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { continue }
            results.append(pngData.base64EncodedString())
        }
        return results
    }
}
