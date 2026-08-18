import Foundation

@MainActor
final class PaperStore: ObservableObject {
    @Published var papers: [Paper] {
        didSet { persist() }
    }

    private static let key = "maziar.papers"

    init() {
        papers = Self.loadPapers()
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        papers = Self.loadPapers()
    }

    private static func loadPapers() -> [Paper] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Paper].self, from: data) else {
            return []
        }
        return decoded
    }

    @discardableResult
    func add(title: String) -> Paper {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let paper = Paper(title: trimmed.isEmpty ? "Untitled Paper" : trimmed)
        papers.insert(paper, at: 0)
        return paper
    }

    func remove(_ paper: Paper) {
        papers.removeAll { $0.id == paper.id }
    }

    func update(_ paper: Paper) {
        guard let index = papers.firstIndex(where: { $0.id == paper.id }) else { return }
        var updated = paper
        updated.lastUpdated = Date()
        papers[index] = updated
    }

    func moveUp(_ paper: Paper) {
        guard let index = papers.firstIndex(where: { $0.id == paper.id }), index > 0 else { return }
        papers.swapAt(index, index - 1)
    }

    func moveDown(_ paper: Paper) {
        guard let index = papers.firstIndex(where: { $0.id == paper.id }), index < papers.count - 1 else { return }
        papers.swapAt(index, index + 1)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(papers) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
