import Foundation

@MainActor
final class ShareViewModel: ObservableObject {
    let project: Project

    @Published var isGitRepo = false
    @Published var currentBranch: String?
    @Published var originURL: String = ""
    @Published var overleafProjectId: String = ""
    @Published var overleafToken: String = ""
    @Published var overleafLinked = false
    @Published var isBusy = false
    @Published var log = ""
    @Published var errorMessage: String?

    private static let overleafRemoteName = "overleaf"

    init(project: Project) {
        self.project = project
        refresh()
    }

    func refresh() {
        isGitRepo = GitService.isRepo(at: project.url)
        currentBranch = GitService.currentBranch(at: project.url)
        originURL = GitService.remoteURL(name: "origin", at: project.url) ?? ""

        if let overleafRemote = GitService.remoteURL(name: Self.overleafRemoteName, at: project.url),
           let id = Self.projectId(fromRemote: overleafRemote) {
            overleafProjectId = id
            overleafLinked = true
            overleafToken = KeychainHelper.get(forKey: Self.tokenKey(for: id)) ?? ""
        } else {
            overleafLinked = false
        }
    }

    private static func tokenKey(for projectId: String) -> String { "overleaf-token:\(projectId)" }

    private static func projectId(fromRemote remote: String) -> String? {
        guard let url = URL(string: remote) else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty ? nil : id
    }

    // MARK: - Generic git

    func initGitRepo() async {
        await perform("Initializing git repository...") {
            _ = try await GitService.initRepo(at: self.project.url)
        }
    }

    func setOrigin() async {
        guard !originURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform("Setting remote 'origin'...") {
            if !GitService.isRepo(at: self.project.url) {
                _ = try await GitService.initRepo(at: self.project.url)
            }
            _ = try await GitService.setRemote(name: "origin", url: self.originURL, at: self.project.url)
        }
    }

    func push() async {
        await perform("Pushing to origin...") {
            _ = try? await GitService.commitAll(message: "Maziar sync", at: self.project.url)
            _ = try await GitService.push(remote: "origin", branch: self.currentBranch, at: self.project.url)
        }
    }

    func pull() async {
        await perform("Pulling from origin...") {
            _ = try await GitService.pull(remote: "origin", branch: self.currentBranch, at: self.project.url)
        }
    }

    // MARK: - Overleaf Git Bridge

    func linkOverleaf() async {
        let id = overleafProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = overleafToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !token.isEmpty else {
            errorMessage = "Enter your Overleaf project ID and a git token from Overleaf's Account Settings."
            return
        }
        await perform("Linking to Overleaf project \(id)...") {
            if !GitService.isRepo(at: self.project.url) {
                _ = try await GitService.initRepo(at: self.project.url)
            }
            // Stored token-free; the token is fetched from Keychain and embedded only for the duration of a push/pull.
            _ = try await GitService.setRemote(
                name: Self.overleafRemoteName, url: "https://git.overleaf.com/\(id)", at: self.project.url
            )
            KeychainHelper.set(token, forKey: Self.tokenKey(for: id))
        }
    }

    func pullFromOverleaf() async {
        await withOverleafCredentials { remote in
            _ = try await GitService.pull(remote: remote, branch: nil, at: self.project.url)
        }
    }

    func pushToOverleaf() async {
        await withOverleafCredentials { remote in
            _ = try? await GitService.commitAll(message: "Maziar sync", at: self.project.url)
            _ = try await GitService.push(remote: remote, branch: nil, at: self.project.url)
        }
    }

    /// Temporarily embeds the Keychain-stored token into the "overleaf" remote URL for one
    /// git operation, then restores the token-free URL, so the secret never sits at rest in .git/config.
    private func withOverleafCredentials(_ operation: @escaping (String) async throws -> Void) async {
        let id = overleafProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            errorMessage = "Link an Overleaf project first."
            return
        }
        guard let token = KeychainHelper.get(forKey: Self.tokenKey(for: id)) else {
            errorMessage = "No saved Overleaf token found. Link the project again."
            return
        }
        await perform("Syncing with Overleaf...") {
            let authedURL = "https://git:\(token)@git.overleaf.com/\(id)"
            let tokenFreeURL = "https://git.overleaf.com/\(id)"
            _ = try await GitService.setRemote(name: Self.overleafRemoteName, url: authedURL, at: self.project.url)
            do {
                try await operation(Self.overleafRemoteName)
            } catch {
                _ = try? await GitService.setRemote(name: Self.overleafRemoteName, url: tokenFreeURL, at: self.project.url)
                throw error
            }
            _ = try? await GitService.setRemote(name: Self.overleafRemoteName, url: tokenFreeURL, at: self.project.url)
        }
    }

    // MARK: - Helpers

    private func perform(_ label: String, _ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        log += "\(label)\n"
        defer { isBusy = false }
        do {
            try await work()
            log += "Done.\n"
        } catch {
            errorMessage = error.localizedDescription
            log += "Error: \(error.localizedDescription)\n"
        }
        refresh()
    }
}
