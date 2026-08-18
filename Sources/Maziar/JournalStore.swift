import Foundation

@MainActor
final class JournalStore: ObservableObject {
    @Published var journals: [JournalEntry] {
        didSet { persist() }
    }
    /// Reference sites (Scimago, JCR, DOAJ, etc.) suggested to the AI as search starting points
    /// on every journal lookup — see `JournalInfoService`.
    @Published var helperWebsites: [String] {
        didSet { UserDefaults.standard.set(helperWebsites, forKey: Self.helperWebsitesKey) }
    }

    private static let key = "maziar.journals"
    private static let helperWebsitesKey = "maziar.journals.helperWebsites"

    static let defaultHelperWebsites = [
        "https://www.scimagojr.com/",
        "https://jcr.clarivate.com/",
        "https://doaj.org/"
    ]

    init() {
        journals = Self.loadJournals()
        helperWebsites = UserDefaults.standard.stringArray(forKey: Self.helperWebsitesKey) ?? Self.defaultHelperWebsites
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        journals = Self.loadJournals()
        helperWebsites = UserDefaults.standard.stringArray(forKey: Self.helperWebsitesKey) ?? Self.defaultHelperWebsites
    }

    private static func loadJournals() -> [JournalEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    @discardableResult
    func addHelperWebsite(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !helperWebsites.contains(trimmed) else { return false }
        helperWebsites.append(trimmed)
        return true
    }

    func removeHelperWebsite(_ url: String) {
        helperWebsites.removeAll { $0 == url }
    }

    @discardableResult
    func add(name: String, fullName: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !journals.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        let trimmedFullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        journals.append(JournalEntry(name: trimmed, fullName: (trimmedFullName?.isEmpty ?? true) ? nil : trimmedFullName))
        return true
    }

    func remove(_ entry: JournalEntry) {
        journals.removeAll { $0.id == entry.id }
    }

    /// Merges a previously-exported JSON list back in — e.g. after reinstalling the app, or moving
    /// to a new Mac, without going through the full Settings backup/restore. Matches by name
    /// (case-insensitive) so re-importing the same file is idempotent: an existing tracked journal
    /// is replaced wholesale by the imported one (including its rank/links/notes), anything new is
    /// appended. Returns the number of entries processed.
    @discardableResult
    func importEntries(_ entries: [JournalEntry]) -> Int {
        for imported in entries {
            if let index = journals.firstIndex(where: { $0.name.caseInsensitiveCompare(imported.name) == .orderedSame }) {
                journals[index] = imported
            } else {
                journals.append(imported)
            }
        }
        return entries.count
    }

    func update(_ entry: JournalEntry) {
        guard let index = journals.firstIndex(where: { $0.id == entry.id }) else { return }
        journals[index] = entry
    }

    /// Array order is the persisted, user-visible order — these just swap neighbors.
    func moveUp(_ entry: JournalEntry) {
        guard let index = journals.firstIndex(where: { $0.id == entry.id }), index > 0 else { return }
        journals.swapAt(index, index - 1)
    }

    func moveDown(_ entry: JournalEntry) {
        guard let index = journals.firstIndex(where: { $0.id == entry.id }), index < journals.count - 1 else { return }
        journals.swapAt(index, index + 1)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(journals) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
