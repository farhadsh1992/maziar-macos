import Foundation

/// Thin wrapper around the `git` CLI for the Share sheet's git-collaboration
/// and Overleaf Git Bridge features.
enum GitService {
    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func isRepo(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }

    static func currentBranch(at directory: URL) -> String? {
        try? run(["rev-parse", "--abbrev-ref", "HEAD"], at: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remoteURL(name: String, at directory: URL) -> String? {
        let value = try? run(["remote", "get-url", name], at: directory)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func initRepo(at directory: URL) async throws -> String {
        try await runAsync(["init"], at: directory)
    }

    @discardableResult
    static func setRemote(name: String, url: String, at directory: URL) async throws -> String {
        // Replace if it already exists.
        _ = try? await runAsync(["remote", "remove", name], at: directory)
        return try await runAsync(["remote", "add", name, url], at: directory)
    }

    @discardableResult
    static func commitAll(message: String, at directory: URL) async throws -> String {
        _ = try? await runAsync(["add", "-A"], at: directory)
        return try await runAsync(["commit", "-m", message, "--allow-empty-message", "--quiet"], at: directory)
    }

    @discardableResult
    static func push(remote: String, branch: String?, at directory: URL) async throws -> String {
        var args = ["push", remote]
        if let branch { args.append(branch) }
        return try await runAsync(args, at: directory)
    }

    @discardableResult
    static func pull(remote: String, branch: String?, at directory: URL) async throws -> String {
        var args = ["pull", remote]
        if let branch { args.append(branch) }
        return try await runAsync(args, at: directory)
    }

    @discardableResult
    static func clone(url: String, into destination: URL) async throws -> String {
        try await runAsync(["clone", url, destination.path], at: destination.deletingLastPathComponent())
    }

    // MARK: - Process plumbing

    private static func runAsync(_ arguments: [String], at directory: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try run(arguments, at: directory)
        }.value
    }

    @discardableResult
    private static func run(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw GitError(message: output.isEmpty ? "git \(arguments.joined(separator: " ")) failed." : output)
        }
        return output
    }
}
