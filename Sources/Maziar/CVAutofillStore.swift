import Foundation

/// A free-form note added via the CV AutoFill panel's "Add info" — anything worth the AI knowing
/// beyond the CV itself, folded into cover-letter/tailored-CV/autofill prompts as extra context.
struct CVAutofillNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var content: String
}

/// A labeled physical address (home, work, mailing) — used to fill address-shaped form fields
/// (street, city, postal code, country) during autofill, same idea as the browser extension's own
/// Info → Addresses list.
struct CVAutofillAddress: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var content: String
}

/// One job saved via the CV AutoFill panel's "Save this job" — scraped best-effort from the current
/// page, not hand-entered. `results` is the only field a user edits by hand afterward (e.g.
/// "Interviewed", "Rejected", "Offer"), matching the extension's own Jobs table.
struct CVAutofillSavedJob: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var company: String
    var link: String
    var savedAt: Date
    var results: String

    init(id: UUID = UUID(), title: String, company: String, link: String, savedAt: Date = Date(), results: String = "") {
        self.id = id
        self.title = title
        self.company = company
        self.link = link
        self.savedAt = savedAt
        self.results = results
    }

    private enum CodingKeys: String, CodingKey { case id, title, company, link, savedAt, results }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? ""
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        results = try container.decodeIfPresent(String.self, forKey: .results) ?? ""
    }
}

/// What one Quick Access button does when clicked — copies a saved snippet of text/link to the
/// clipboard, or opens a local file (e.g. a portfolio PDF) via `NSWorkspace`.
enum CVAutofillQuickAccessType: String, Codable, CaseIterable, Identifiable {
    case copyText
    case copyLink
    case openFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyText: return "Copy text"
        case .copyLink: return "Copy a link"
        case .openFile: return "Open a local file"
        }
    }
}

/// One small icon-only button shown in the CV AutoFill panel — same idea as the extension's own
/// Quick Access grid, minus its brand-favicon fetching (a plain emoji/character icon here instead).
struct CVAutofillQuickAccessItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var icon: String
    var type: CVAutofillQuickAccessType
    var value: String
    var label: String
}

/// Which chat site the CV AutoFill panel's "Ask ChatGPT"/"Ask Claude" button opens — same idea and
/// same underlying mechanism as `ReaderAIChatSource` (Settings → Library's Reader AI Chat picker),
/// kept as its own separate enum since the two pickers are independent of each other.
enum CVAutofillAskAITarget: String, CaseIterable, Identifiable, Codable {
    case chatgpt
    case claude

    var id: String { rawValue }

    var buttonLabel: String {
        switch self {
        case .chatgpt: return "Ask ChatGPT"
        case .claude: return "Ask Claude"
        }
    }

    var urlString: String {
        switch self {
        case .chatgpt: return "https://chatgpt.com"
        case .claude: return "https://claude.ai/new"
        }
    }
}

/// Everything `CVAutofillStore` holds, as one flat file — used by Setting → Backup's export/import.
/// Deliberately excludes API keys (Maziar has no separate ones for this feature; it reuses the app's
/// own AI Assistant settings), unlike the browser extension's own backup file.
struct CVAutofillBackup: Codable {
    var structuredCVJSON: String?
    var cvFileName: String?
    var coverLetterText: String?
    var coverLetterFileName: String?
    var notes: [CVAutofillNote]
    var addresses: [CVAutofillAddress]
    var savedJobs: [CVAutofillSavedJob]
    var quickAccessItems: [CVAutofillQuickAccessItem]
    var promptOverrides: [String: String]
    var askAITarget: CVAutofillAskAITarget
}

/// Holds the CV data used by a custom page's "CV AutoFill" panel — its own separate local store
/// inside Maziar (its own settings window, opened from the panel's own "Setting" button), distinct
/// from the standalone "Farhad's CV AutoFill" Mac app/browser extension's own storage — same "own
/// data" split that Mac app already has from the browser extension it's a companion to.
@MainActor
final class CVAutofillStore: ObservableObject {
    /// AI-structured CV JSON (name, contact, work history, education, skills) — see
    /// `CVAutofillService.structureCV`. Fed back into every autofill/generation prompt as context;
    /// never parsed into a rigid Swift model on this side, since nothing here needs individual
    /// fields directly — it only ever gets forwarded as text to another AI call.
    @Published var structuredCVJSON: String? {
        didSet { UserDefaults.standard.set(structuredCVJSON, forKey: Self.structuredCVJSONKey) }
    }
    @Published var cvFileName: String? {
        didSet { UserDefaults.standard.set(cvFileName, forKey: Self.cvFileNameKey) }
    }
    /// A reference cover letter's plain text — used as a style/tone guide for "Generate cover
    /// letter for this page" (never copied verbatim). Extracted locally, no AI call needed just to
    /// read the file, same as the CV's own raw-text extraction step.
    @Published var coverLetterText: String? {
        didSet { UserDefaults.standard.set(coverLetterText, forKey: Self.coverLetterTextKey) }
    }
    @Published var coverLetterFileName: String? {
        didSet { UserDefaults.standard.set(coverLetterFileName, forKey: Self.coverLetterFileNameKey) }
    }
    @Published var notes: [CVAutofillNote] {
        didSet { persistNotes() }
    }
    @Published var addresses: [CVAutofillAddress] {
        didSet { persistAddresses() }
    }
    @Published var savedJobs: [CVAutofillSavedJob] {
        didSet { persistSavedJobs() }
    }
    @Published var quickAccessItems: [CVAutofillQuickAccessItem] {
        didSet { persistQuickAccessItems() }
    }
    /// Keyed by `CVAutofillService.PromptKey.rawValue` — only holds an entry when a prompt has been
    /// edited away from its built-in default (see `promptOverride(for:)`/`setPromptOverride(_:text:)`).
    @Published var promptOverrides: [String: String] {
        didSet { persistPromptOverrides() }
    }
    @Published var askAITarget: CVAutofillAskAITarget {
        didSet { UserDefaults.standard.set(askAITarget.rawValue, forKey: Self.askAITargetKey) }
    }

    private static let structuredCVJSONKey = "maziar.cvAutofill.structuredCVJSON"
    private static let cvFileNameKey = "maziar.cvAutofill.cvFileName"
    private static let coverLetterTextKey = "maziar.cvAutofill.coverLetterText"
    private static let coverLetterFileNameKey = "maziar.cvAutofill.coverLetterFileName"
    private static let notesKey = "maziar.cvAutofill.notes"
    private static let addressesKey = "maziar.cvAutofill.addresses"
    private static let savedJobsKey = "maziar.cvAutofill.savedJobs"
    private static let quickAccessItemsKey = "maziar.cvAutofill.quickAccessItems"
    private static let promptOverridesKey = "maziar.cvAutofill.promptOverrides"
    private static let askAITargetKey = "maziar.cvAutofill.askAITarget"

    var isLoaded: Bool {
        structuredCVJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasCoverLetter: Bool {
        coverLetterText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    init() {
        structuredCVJSON = UserDefaults.standard.string(forKey: Self.structuredCVJSONKey)
        cvFileName = UserDefaults.standard.string(forKey: Self.cvFileNameKey)
        coverLetterText = UserDefaults.standard.string(forKey: Self.coverLetterTextKey)
        coverLetterFileName = UserDefaults.standard.string(forKey: Self.coverLetterFileNameKey)
        notes = Self.loadCodable([CVAutofillNote].self, key: Self.notesKey) ?? []
        addresses = Self.loadCodable([CVAutofillAddress].self, key: Self.addressesKey) ?? []
        savedJobs = Self.loadCodable([CVAutofillSavedJob].self, key: Self.savedJobsKey) ?? []
        quickAccessItems = Self.loadCodable([CVAutofillQuickAccessItem].self, key: Self.quickAccessItemsKey) ?? []
        promptOverrides = Self.loadCodable([String: String].self, key: Self.promptOverridesKey) ?? [:]
        if let raw = UserDefaults.standard.string(forKey: Self.askAITargetKey), let target = CVAutofillAskAITarget(rawValue: raw) {
            askAITarget = target
        } else {
            askAITarget = .chatgpt
        }
    }

    func clearCV() {
        structuredCVJSON = nil
        cvFileName = nil
    }

    func clearCoverLetter() {
        coverLetterText = nil
        coverLetterFileName = nil
    }

    func addNote(title: String, content: String) {
        notes.append(CVAutofillNote(title: title, content: content))
    }

    func removeNote(_ note: CVAutofillNote) {
        notes.removeAll { $0.id == note.id }
    }

    func addAddress(title: String, content: String) {
        addresses.append(CVAutofillAddress(title: title, content: content))
    }

    func removeAddress(_ address: CVAutofillAddress) {
        addresses.removeAll { $0.id == address.id }
    }

    func removeSavedJob(_ job: CVAutofillSavedJob) {
        savedJobs.removeAll { $0.id == job.id }
    }

    func addQuickAccessItem(icon: String, type: CVAutofillQuickAccessType, value: String, label: String) {
        quickAccessItems.append(CVAutofillQuickAccessItem(icon: icon, type: type, value: value, label: label))
    }

    func removeQuickAccessItem(_ item: CVAutofillQuickAccessItem) {
        quickAccessItems.removeAll { $0.id == item.id }
    }

    /// Reorders a button by swapping it with its neighbor — `offset` of -1 moves it earlier, +1 later.
    func moveQuickAccessItem(_ item: CVAutofillQuickAccessItem, offset: Int) {
        guard let index = quickAccessItems.firstIndex(where: { $0.id == item.id }) else { return }
        let newIndex = index + offset
        guard newIndex >= 0, newIndex < quickAccessItems.count else { return }
        quickAccessItems.swapAt(index, newIndex)
    }

    /// nil when the prompt is still at its built-in default — callers should fall back to
    /// `key.defaultPrompt` themselves.
    func promptOverride(for key: CVAutofillService.PromptKey) -> String? {
        guard let value = promptOverrides[key.rawValue],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func setPromptOverride(_ key: CVAutofillService.PromptKey, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == key.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            promptOverrides.removeValue(forKey: key.rawValue)
        } else {
            promptOverrides[key.rawValue] = text
        }
    }

    func resetPrompt(_ key: CVAutofillService.PromptKey) {
        promptOverrides.removeValue(forKey: key.rawValue)
    }

    func exportBackupData() -> Data? {
        let backup = CVAutofillBackup(
            structuredCVJSON: structuredCVJSON,
            cvFileName: cvFileName,
            coverLetterText: coverLetterText,
            coverLetterFileName: coverLetterFileName,
            notes: notes,
            addresses: addresses,
            savedJobs: savedJobs,
            quickAccessItems: quickAccessItems,
            promptOverrides: promptOverrides,
            askAITarget: askAITarget
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(backup)
    }

    func importBackup(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(CVAutofillBackup.self, from: data)
        structuredCVJSON = backup.structuredCVJSON
        cvFileName = backup.cvFileName
        coverLetterText = backup.coverLetterText
        coverLetterFileName = backup.coverLetterFileName
        notes = backup.notes
        addresses = backup.addresses
        savedJobs = backup.savedJobs
        quickAccessItems = backup.quickAccessItems
        promptOverrides = backup.promptOverrides
        askAITarget = backup.askAITarget
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persistNotes() { Self.persist(notes, key: Self.notesKey) }
    private func persistAddresses() { Self.persist(addresses, key: Self.addressesKey) }
    private func persistSavedJobs() { Self.persist(savedJobs, key: Self.savedJobsKey) }
    private func persistQuickAccessItems() { Self.persist(quickAccessItems, key: Self.quickAccessItemsKey) }
    private func persistPromptOverrides() { Self.persist(promptOverrides, key: Self.promptOverridesKey) }

    private static func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
