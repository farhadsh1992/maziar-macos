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
    func add(title: String, kind: ProjectKind = .paperSubmission, parentID: UUID? = nil) -> Paper {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTitle = kind == .developing ? "Untitled Project" : "Untitled Paper"
        let paper = Paper(title: trimmed.isEmpty ? defaultTitle : trimmed, kind: kind, parentID: parentID)
        papers.insert(paper, at: 0)
        return paper
    }

    /// Every project directly nested under `parent` — computed by filtering the flat `papers`
    /// array rather than stored inline, so there's one source of truth regardless of how deep the
    /// nesting goes.
    func children(of parent: Paper) -> [Paper] {
        papers.filter { $0.parentID == parent.id }
    }

    /// Top-level projects only — what the Projects page's main list actually shows; a sub-project
    /// is only reachable from inside its parent.
    func topLevelPapers() -> [Paper] {
        papers.filter { $0.parentID == nil }
    }

    /// Removes `paper` and every descendant beneath it (recursively) — leaving an orphaned
    /// sub-project with a dangling `parentID` and no way to reach it would be worse than a
    /// cascading delete, same reasoning as removing a Library group removes what's only inside it.
    func remove(_ paper: Paper) {
        var idsToRemove: Set<UUID> = [paper.id]
        var frontier = [paper.id]
        while !frontier.isEmpty {
            let nextFrontier = papers.filter { paper in
                guard let parentID = paper.parentID else { return false }
                return frontier.contains(parentID)
            }.map(\.id)
            idsToRemove.formUnion(nextFrontier)
            frontier = nextFrontier
        }
        papers.removeAll { idsToRemove.contains($0.id) }
    }

    func update(_ paper: Paper) {
        guard let index = papers.firstIndex(where: { $0.id == paper.id }) else { return }
        var updated = paper
        updated.lastUpdated = Date()
        papers[index] = updated
    }

    /// Reorders within the same parent (siblings), not raw adjacent array indices — the backing
    /// array interleaves top-level projects and sub-projects freely (new entries are always
    /// prepended at index 0 regardless of nesting depth), so a plain adjacent-index swap could
    /// silently swap a top-level project past an unrelated sub-project sitting between them.
    func moveUp(_ paper: Paper) {
        reorderWithinSiblings(paper) { index, _ in index > 0 ? index - 1 : nil }
    }

    func moveDown(_ paper: Paper) {
        reorderWithinSiblings(paper) { index, count in index < count - 1 ? index + 1 : nil }
    }

    private func reorderWithinSiblings(_ paper: Paper, target: (Int, Int) -> Int?) {
        let siblings = papers.filter { $0.parentID == paper.parentID }
        guard let currentIndex = siblings.firstIndex(where: { $0.id == paper.id }),
              let newIndex = target(currentIndex, siblings.count),
              let globalCurrent = papers.firstIndex(where: { $0.id == siblings[currentIndex].id }),
              let globalTarget = papers.firstIndex(where: { $0.id == siblings[newIndex].id }) else { return }
        papers.swapAt(globalCurrent, globalTarget)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(papers) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
