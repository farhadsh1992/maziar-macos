import Foundation

/// Pure parsing/URL-building helpers for GitHub repository links — no networking, no AI, trivially
/// headlessly testable. Recognizes a repo from any github.com URL, not just the bare repo root (a
/// link to a specific file, folder, issue, or PR still identifies the same `owner/repo`), so
/// whatever page you happen to be on when you hit "Add to Code List" still resolves correctly.
enum GitHubLinkParser {
    struct Repository: Equatable {
        let owner: String
        let name: String
        var fullName: String { "\(owner)/\(name)" }
    }

    static func repository(from url: URL) -> Repository? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var name = components[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return Repository(owner: owner, name: name)
    }

    static func repository(fromPastedText text: String) -> Repository? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare "owner/repo" typed directly, no URL at all.
        let bareComponents = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if bareComponents.count == 2, !trimmed.contains("://"), !trimmed.contains(" ") {
            return Repository(owner: String(bareComponents[0]), name: String(bareComponents[1]))
        }
        guard let url = URL(string: trimmed) else { return nil }
        return repository(from: url)
    }

    static func repoURL(for repo: Repository) -> URL {
        URL(string: "https://github.com/\(repo.owner)/\(repo.name)")!
    }

    /// `archive/HEAD.zip` resolves to the repo's actual default branch (`main`, `master`, or
    /// anything else) without needing to know its name — GitHub redirects it to a codeload URL for
    /// whatever the current default branch actually is.
    static func zipDownloadURL(for repo: Repository) -> URL {
        URL(string: "https://github.com/\(repo.owner)/\(repo.name)/archive/HEAD.zip")!
    }
}
