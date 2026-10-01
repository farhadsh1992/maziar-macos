import Foundation

/// AI-backed pieces of the CV AutoFill panel: turning raw extracted CV text into structured JSON
/// once (Settings → CV AutoFill), and — given a scanned page's form fields plus that structured
/// CV — proposing values for each field the "Autofill this page" button then writes in. Uses
/// whichever AI provider the AI Assistant is currently set to, same choice `LibraryMetadataService`
/// and friends already make for similar one-shot extraction tasks.
@MainActor
enum CVAutofillService {
    /// One form field found on the current page, reported by the JS scan `CustomWebPageView`
    /// injects — `id` is a synthetic tag the scan script stamps onto the DOM element itself
    /// (`data-maziar-autofill-id`), used afterward to target that exact element when filling it in.
    struct AutofillFieldDescriptor: Codable {
        let id: String
        let label: String
        let type: String
    }

    /// The current page's own content, scraped once by a shared JS snippet and reused as job
    /// context for cover-letter/tailored-CV generation, "Save this job," and "Add to Calendar" —
    /// one scrape, several downstream prompts.
    struct PageContext {
        let title: String
        let url: String
        let text: String
    }

    struct JobInfo: Decodable {
        var title: String?
        var company: String?
    }

    struct CalendarEventInfo: Decodable {
        var title: String?
        /// ISO 8601 (`YYYY-MM-DD` or full date-time) — nil when the page states no clear date.
        var date: String?
        var location: String?
        var notes: String?
    }

    enum ServiceError: LocalizedError {
        case noText
        case unparseableReply(provider: String, preview: String)

        var errorDescription: String? {
            switch self {
            case .noText:
                return "Couldn't read any text from that file."
            case .unparseableReply(let provider, let preview):
                return "Couldn't parse \(provider)'s response as JSON. Raw reply: \(preview)"
            }
        }
    }

    /// Identifies each AI-backed prompt the CV AutoFill panel sends, so Setting → Prompts can list,
    /// edit, and reset them individually — same idea as the browser extension's own Prompts tab,
    /// minus the pieces Maziar doesn't implement (its own built-in Ask AI chat, PDF-text extraction
    /// — done locally here, not via AI — and the right-click "Fill this field" action).
    enum PromptKey: String, CaseIterable, Identifiable {
        case cvSchema
        case fieldMap
        case coverLetterWrite
        case cvTailor
        case jobExtract
        case eventExtract

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cvSchema: return "Parse CV"
            case .fieldMap: return "Autofill this page"
            case .coverLetterWrite: return "Generate cover letter"
            case .cvTailor: return "Tailor CV (Word)"
            case .jobExtract: return "Save this job"
            case .eventExtract: return "Add to Calendar"
            }
        }

        var subtitle: String {
            switch self {
            case .cvSchema:
                return "Used whenever a CV is uploaded, to extract it into structured fields."
            case .fieldMap:
                return "Used by the panel's \u{201c}Autofill this page,\u{201d} to map your CV/context onto a scraped web form's fields."
            case .coverLetterWrite:
                return "Used by \u{201c}Generate cover letter for this page.\u{201d}"
            case .cvTailor:
                return "Used by \u{201c}Generate tailored CV (Word).\u{201d}"
            case .jobExtract:
                return "Used by \u{201c}Save this job,\u{201d} to extract title/company from the page."
            case .eventExtract:
                return "Used by \u{201c}Add to Calendar,\u{201d} to find an event/date on the current page."
            }
        }

        var defaultPrompt: String {
            switch self {
            case .cvSchema: return CVAutofillService.defaultCVSchemaPrompt
            case .fieldMap: return CVAutofillService.defaultFieldMapPrompt
            case .coverLetterWrite: return CVAutofillService.defaultCoverLetterPrompt
            case .cvTailor: return CVAutofillService.defaultCVTailorPrompt
            case .jobExtract: return CVAutofillService.defaultJobExtractPrompt
            case .eventExtract: return CVAutofillService.defaultEventExtractPrompt
            }
        }
    }

    private static func resolvedPrompt(_ override: String?, default defaultPrompt: String) -> String {
        guard let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultPrompt
        }
        return override
    }

    nonisolated static let defaultCVSchemaPrompt = """
    You convert raw CV/resume text into structured JSON, later used to fill out job \
    application form fields. Extract: full name, email, phone, location, LinkedIn URL, \
    personal website, a short professional summary, work history (company, title, start \
    date, end date, bullet points), education (school, degree, field, dates), and a flat \
    list of skills. Use null or an empty array for anything not present in the text — never \
    invent facts.

    Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
    fences.
    """

    nonisolated static let defaultFieldMapPrompt = """
    You fill out a job application form using a candidate's CV data. You're given a JSON \
    array of form fields (each with an "id", a human-readable "label" describing what it \
    asks for, and its input "type"), and the candidate's structured CV data as JSON.

    For each field you can confidently answer from the CV data, propose a value. Skip \
    fields you're not confident about (essay-style questions needing real judgment, or \
    anything the CV data doesn't cover) — never invent facts, and never guess at fields \
    like passwords, verification codes, or file uploads.

    Respond with ONLY a single flat JSON object mapping each field's "id" to its proposed \
    string value, and nothing else — no prose, no markdown code fences, no nested objects. \
    Omit any field you're skipping rather than including it with an empty value.
    """

    nonisolated static let defaultCoverLetterPrompt = """
    You write a cover letter for a job application, grounded in the candidate's real CV data \
    — never invent experience, skills, or facts not present in it. Write roughly one full \
    page, addressed generically if no hiring manager name is evident from the job posting. \
    Do not repeat contact info at the end (that belongs on the CV, not the letter). Respond \
    with ONLY the letter's body text — no subject line, no markdown, no commentary before or \
    after it.
    """

    nonisolated static let defaultCVTailorPrompt = """
    You re-emphasize and reorder a candidate's real CV content for a specific job posting — \
    never invent new facts, companies, titles, or skills not already in their CV data. \
    Produce a clean, plain-text CV: a short summary tailored to the role, then work history \
    (company, title, dates, bullet points re-ordered/re-worded to foreground what's most \
    relevant to this job), then education, then skills. Respond with ONLY the CV's plain \
    text, using blank lines between sections — no markdown, no commentary.
    """

    nonisolated static let defaultJobExtractPrompt = """
    You read a job-posting web page's title and visible text, and identify the job title and \
    hiring company. Use null for whichever you can't confidently determine.

    Respond with ONLY a single JSON object and nothing else: {"title": string or null, \
    "company": string or null}
    """

    nonisolated static let defaultEventExtractPrompt = """
    You read a web page's title and visible text, looking for a specific date/event worth \
    adding to a calendar (an application deadline, an interview time, an event date). Use \
    null for anything not clearly stated — never guess a date that isn't actually on the \
    page. When a date is found, express it in ISO 8601 (\"YYYY-MM-DD\" if only a date is \
    given, or a full date-time if a time is also given).

    Respond with ONLY a single JSON object and nothing else: {"title": string or null, \
    "date": string or null, "location": string or null, "notes": string or null}
    """

    static func structureCV(fromText text: String, settings: AISettings, promptOverride: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.noText }

        let systemPrompt = resolvedPrompt(promptOverride, default: defaultCVSchemaPrompt)

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: trimmed)],
            modelOverride: model
        )
        guard let jsonString = extractJSONObjectString(from: reply) else {
            let preview = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            throw ServiceError.unparseableReply(provider: provider.displayName, preview: preview)
        }
        return jsonString
    }

    static func proposeAutofillValues(fields: [AutofillFieldDescriptor], cvJSON: String, settings: AISettings, promptOverride: String? = nil) async throws -> [String: String] {
        let fieldsData = (try? JSONEncoder().encode(fields)) ?? Data()
        let fieldsJSON = String(data: fieldsData, encoding: .utf8) ?? "[]"

        let systemPrompt = resolvedPrompt(promptOverride, default: defaultFieldMapPrompt)
        let userContent = "Form fields:\n\(fieldsJSON)\n\nCV data:\n\(cvJSON)"

        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userContent)],
            modelOverride: model
        )
        guard let mapping = JSONExtraction.decodeObject([String: String].self, from: reply) else {
            let preview = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            throw ServiceError.unparseableReply(provider: provider.displayName, preview: preview)
        }
        return mapping
    }

    /// Drafts a cover letter grounded in the candidate's CV, in the voice of a saved reference
    /// letter when one's set (never copied verbatim) — same idea as the browser extension's own
    /// "Generate cover letter for this page."
    static func generateCoverLetter(context: PageContext, cvJSON: String, referenceLetter: String?, notes: [CVAutofillNote], settings: AISettings, promptOverride: String? = nil) async throws -> String {
        var systemPrompt = resolvedPrompt(promptOverride, default: defaultCoverLetterPrompt)
        if let referenceLetter, !referenceLetter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt += "\n\nMatch the voice/tone/style of this reference letter (a past letter of the candidate's own), without copying its content verbatim:\n\(referenceLetter)"
        }

        let userContent = promptContent(context: context, cvJSON: cvJSON, notes: notes)
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        return try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userContent)],
            modelOverride: model
        )
    }

    /// Re-emphasizes/reorders the candidate's *real* CV content for a specific job — never invents
    /// new facts — as plain section text, downloaded via `DOCXBuilder`.
    static func generateTailoredCV(context: PageContext, cvJSON: String, notes: [CVAutofillNote], settings: AISettings, promptOverride: String? = nil) async throws -> String {
        let systemPrompt = resolvedPrompt(promptOverride, default: defaultCVTailorPrompt)
        let userContent = promptContent(context: context, cvJSON: cvJSON, notes: notes)
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        return try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userContent)],
            modelOverride: model
        )
    }

    /// Best-effort job title/company for "Save this job" — the page's URL is used as-is (no AI
    /// needed for that part).
    static func extractJobInfo(context: PageContext, settings: AISettings, promptOverride: String? = nil) async throws -> JobInfo {
        let systemPrompt = resolvedPrompt(promptOverride, default: defaultJobExtractPrompt)
        let userContent = "Page title: \(context.title)\nURL: \(context.url)\n\nVisible text:\n\(context.text)"
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider, settings: settings, systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userContent)], modelOverride: model
        )
        return JSONExtraction.decodeObject(JobInfo.self, from: reply) ?? JobInfo(title: nil, company: nil)
    }

    /// Scrapes a job posting or event page for a date to add to Calendar — same idea as the
    /// extension's own "Add to Calendar," minus its Google/Apple Calendar picker (Maziar hands the
    /// result to Calendar.app via a generated `.ics` file instead — see `CVAutofillPanel`).
    static func extractEventInfo(context: PageContext, settings: AISettings, promptOverride: String? = nil) async throws -> CalendarEventInfo {
        let systemPrompt = resolvedPrompt(promptOverride, default: defaultEventExtractPrompt)
        let userContent = "Page title: \(context.title)\nURL: \(context.url)\n\nVisible text:\n\(context.text)"
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider, settings: settings, systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: userContent)], modelOverride: model
        )
        guard let info = JSONExtraction.decodeObject(CalendarEventInfo.self, from: reply) else {
            let preview = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            throw ServiceError.unparseableReply(provider: provider.displayName, preview: preview)
        }
        return info
    }

    private static func promptContent(context: PageContext, cvJSON: String, notes: [CVAutofillNote]) -> String {
        var content = "Job posting page title: \(context.title)\nURL: \(context.url)\n\nJob posting visible text:\n\(context.text)\n\nCandidate's CV data:\n\(cvJSON)"
        if !notes.isEmpty {
            let notesText = notes.map { "- \($0.title): \($0.content)" }.joined(separator: "\n")
            content += "\n\nAdditional candidate context:\n\(notesText)"
        }
        return content
    }

    /// Same fence-stripping idea as `JSONExtraction`, kept separate since that enum's helpers all
    /// return a decoded `Decodable` value — the structured CV JSON is deliberately never decoded on
    /// this side (it only ever gets forwarded as text into a later prompt), so this just needs the
    /// raw matched substring.
    private static func extractJSONObjectString(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\n([\\s\\S]*?)```"),
           let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
           let range = Range(match.range(at: 1), in: candidate) {
            candidate = String(candidate[range])
        }
        guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        return String(candidate[start...end])
    }
}
