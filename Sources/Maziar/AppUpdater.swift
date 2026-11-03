import Foundation
import AppKit
import UserNotifications

/// Checks GitHub for a newer version of Maziar and can update the app in place.
///
/// Maziar is built from source (`build_app.sh`), not shipped as a downloadable binary, so "update"
/// means: pull the repository checkout this app was built from, rebuild it, and relaunch. The build
/// script stamps the running app with the commit it came from and the checkout's path
/// (`MaziarGitCommit`/`MaziarRepoPath` in Info.plist); an update is available when `origin/main` has
/// commits the stamped one doesn't. A copy of the app with no checkout behind it can still *check*
/// (via GitHub's API) but can't update itself.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// The human-readable release name shown in About, Settings and the About panel. Bump this (and
    /// the numeric `3.0.2` in `build_app.sh`) when cutting a new release.
    static let versionLabel = "Beta 3.0.2"

    private static let repoSlug = "farhadsh1992/maziar-macos"
    private static let autoCheckKey = "maziar.updater.autoCheck"
    private static let lastCheckKey = "maziar.updater.lastCheck"
    private static let promptedKey = "maziar.updater.promptedCommit"
    private static let interval: TimeInterval = 7 * 24 * 3600

    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) } }
    @Published private(set) var lastCheck: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var availableCommit: String?
    @Published private(set) var changes: [String] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress: String?

    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    let builtCommit: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "MaziarGitCommit") as? String
        return (value == nil || value == "unknown" || value?.isEmpty == true) ? nil : value
    }()
    let buildDate: String? = Bundle.main.object(forInfoDictionaryKey: "MaziarBuildDate") as? String
    private let repoPath: String? = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MaziarRepoPath") as? String,
              FileManager.default.fileExists(atPath: path + "/.git"),
              FileManager.default.fileExists(atPath: path + "/build_app.sh") else { return nil }
        return path
    }()

    var canSelfUpdate: Bool { repoPath != nil && builtCommit != nil }
    var shortVersion: String { builtCommit.map { String($0.prefix(7)) } ?? "unknown" }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - Scheduling

    /// Called once at launch: checks if a week has passed since the last check (and then keeps
    /// re-evaluating every few hours while the app stays open), and shows any pending update prompt
    /// whenever the app comes to the front.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.promptIfNeeded() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await checkIfDue()
        }
    }

    private func checkIfDue() async {
        guard autoCheck else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        await check()
        promptIfNeeded()
    }

    // MARK: - Check

    /// The "Check for Updates" button/menu item: checks now and always tells you the result.
    func checkAndReport() async {
        await check()
        if availableCommit != nil {
            presentUpdateAlert()
        } else {
            let alert = NSAlert()
            alert.messageText = errorMessage == nil ? "Maziar is up to date" : "Couldn't check for updates"
            alert.informativeText = errorMessage ?? statusMessage ?? ""
            alert.runModal()
        }
    }

    func check() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        errorMessage = nil
        statusMessage = nil
        defer { isChecking = false }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
        do {
            let remote: String
            var summary: [String] = []
            if let repoPath {
                let fetch = await Self.run("/usr/bin/git", ["-C", repoPath, "fetch", "--quiet", "origin", "main"])
                guard fetch.status == 0 else { throw UpdateError.message("git fetch failed: \(fetch.output)") }
                remote = (await Self.run("/usr/bin/git", ["-C", repoPath, "rev-parse", "origin/main"])).output.trimmed
                guard let built = builtCommit else { throw UpdateError.message("This copy of Maziar doesn't know which version it is. Rebuild it once with build_app.sh and it will.") }
                // Up to date if GitHub's tip is what we're running, or is already part of our history.
                var isCurrent = remote == built
                if !isCurrent {
                    isCurrent = (await Self.run("/usr/bin/git", ["-C", repoPath, "merge-base", "--is-ancestor", remote, built])).status == 0
                }
                if isCurrent {
                    availableCommit = nil
                    statusMessage = "You have the latest version (\(shortVersion))."
                    return
                }
                let log = await Self.run("/usr/bin/git", ["-C", repoPath, "log", "--no-decorate", "--format=%s", "\(built)..\(remote)"])
                summary = log.status == 0 ? log.output.split(separator: "\n").map(String.init) : []
            } else {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repoSlug)/commits/main")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sha = json["sha"] as? String else {
                    throw UpdateError.message("Couldn't read the GitHub repository (it may be private — update from a local checkout instead).")
                }
                remote = sha
                if let built = builtCommit, built == sha {
                    availableCommit = nil
                    statusMessage = "You have the latest version (\(shortVersion))."
                    return
                }
                if let commit = json["commit"] as? [String: Any], let message = commit["message"] as? String {
                    summary = [message.components(separatedBy: "\n").first ?? message]
                }
            }
            availableCommit = remote
            changes = summary
            statusMessage = "A newer version is available (\(remote.prefix(7)))."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Prompt / notify

    /// Shows the "update available" prompt once per new version, and only while Maziar is in front.
    private func promptIfNeeded() {
        guard let commit = availableCommit, !isUpdating,
              UserDefaults.standard.string(forKey: Self.promptedKey) != commit else { return }
        postNotification()
        guard NSApp.isActive else { return }
        UserDefaults.standard.set(commit, forKey: Self.promptedKey)
        presentUpdateAlert()
    }

    private func postNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Maziar update available"
            content.body = "A newer version is on GitHub. Open Maziar to update."
            center.add(UNNotificationRequest(identifier: "maziar-update", content: content, trigger: nil))
        }
    }

    private func presentUpdateAlert() {
        guard availableCommit != nil else { return }
        let alert = NSAlert()
        alert.messageText = "A new version of Maziar is available"
        // "You have Beta 3.0.2 (abc1234)" so it's clear what you'd be replacing.
        let list = changes.prefix(8).map { "\u{2022} \($0)" }.joined(separator: "\n")
        var text = "You have \(Self.versionLabel) (\(shortVersion)).\n\n" + (list.isEmpty ? "There are newer changes on GitHub." : "What's new:\n\(list)")
        if !canSelfUpdate {
            text += "\n\nThis copy isn't linked to a source checkout, so it can't update itself — on this Mac run `git pull && ./build_app.sh release` in the project folder."
        }
        alert.informativeText = text
        if canSelfUpdate { alert.addButton(withTitle: "Update Now") }
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, canSelfUpdate {
            Task { await update() }
        }
    }

    // MARK: - Update

    /// Pulls the checkout this app was built from, rebuilds it, and relaunches into the new build.
    func update() async {
        guard let repoPath, !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false; progress = nil }
        do {
            progress = "Downloading the update from GitHub…"
            let pull = await Self.run("/usr/bin/git", ["-C", repoPath, "pull", "--ff-only", "origin", "main"])
            guard pull.status == 0 else {
                throw UpdateError.message("Couldn't pull the update (local changes in the checkout may conflict):\n\(pull.output.lastLines(8))")
            }
            progress = "Building the new version — this takes about a minute…"
            let build = await Self.run("/bin/bash", ["\(repoPath)/build_app.sh", "release"], directory: repoPath)
            guard build.status == 0 else {
                throw UpdateError.message("The build failed (is Xcode or the Command Line Tools installed?):\n\(build.output.lastLines(10))")
            }
            progress = "Restarting Maziar…"
            let newApp = "\(repoPath)/dist/Maziar.app"
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1.5; open \"$1\"", "sh", newApp]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text } else { return nil } }
    }

    /// Runs a tool off the main thread with a normal shell-ish PATH (a GUI app's own PATH is bare).
    nonisolated private static func run(_ tool: String, _ arguments: [String], directory: String? = nil) async -> (status: Int32, output: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func lastLines(_ count: Int) -> String {
        split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
    }
}
