import Foundation
import AppKit
import Darwin
import CryptoKit

/// Runs Numenor — Maziar's second LaTeX editor, a Node.js app (React frontend, Fastify backend) based on
/// Numenor — as a local server so Maziar can embed its web UI.
///
/// Numenor's source ships with Maziar: it lives in the maziar repo's `Numenor/` folder (also published on
/// its own as github.com/farhadsh1992/numenor), and `build_app.sh` copies it into the app bundle's
/// Resources. Node code can't be linked into a Swift binary, so Maziar manages it as a child process:
///   1. **Set up** — copy the bundled source into `~/Library/Application Support/Maziar/Numenor/app`,
///      `npm install` (only when `package-lock.json` changed) and `npm run build`. This re-runs by itself
///      whenever the bundled source differs from what was set up last (tracked by a digest marker), so a
///      new Maziar build brings its Numenor changes along without any download.
///   2. **Start** — `node apps/backend/src/index.js` on a free localhost port; that one process serves both
///      the UI and the API. Maziar's settings go in through the environment (`NUMENOR_*`).
///   3. **Stop** — when the app quits (or from the page's toolbar).
///
/// Projects live in `…/Maziar/Numenor/data` (`NUMENOR_DATA_DIR`), outside the code folder, so re-setting up
/// never touches them. When Google Drive sync is on, `DriveNumenorSync` keeps them in step with the other Mac.
/// Installs from the OpenPrism days (`…/Maziar/OpenPrism`) are moved over on first use.
@MainActor
final class NumenorServer: ObservableObject {
    static let shared = NumenorServer()

    enum State: Equatable {
        case notInstalled
        /// Setting up — the string is the current step, shown above the log.
        case working(String)
        case stopped
        case starting
        case running(URL)
        case failed(String)
    }

    /// The AI Numenor talks to — Maziar's own provider, model and key (Settings \u{2192} AI), handed to the
    /// server through its environment. The server's environment is fixed when it starts, so changing this
    /// while it runs restarts it.
    struct AIConfig: Equatable {
        let endpoint: String
        let apiKey: String
        let model: String
        let label: String
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var aiConfig: AIConfig?
    /// Output of the setup steps and of the server itself (last ~30 000 characters).
    @Published private(set) var log = ""

    private var process: Process?
    private var stopRequested = false
    private var starting = false

    private var baseDirectory: URL { DriveNumenorSync.baseDirectory }
    private var appDirectory: URL { baseDirectory.appendingPathComponent("app", isDirectory: true) }
    private var dataDirectory: URL { baseDirectory.appendingPathComponent("data", isDirectory: true) }
    private var pidFile: URL { baseDirectory.appendingPathComponent("server.pid") }
    private var sourceMarker: URL { appDirectory.appendingPathComponent(".maziar-source") }
    private var lockMarker: URL { appDirectory.appendingPathComponent(".maziar-lock") }

    /// Numenor's source as shipped with this Maziar: in the .app's Resources, or — when running a debug build
    /// straight from the checkout — the repo's own `Numenor/` folder.
    static var bundledSource: URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Numenor", isDirectory: true),
           fm.fileExists(atPath: resources.appendingPathComponent("package.json").path) {
            return resources
        }
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Numenor", isDirectory: true)
        return fm.fileExists(atPath: checkout.appendingPathComponent("package.json").path) ? checkout : nil
    }

    /// The `MaziarSpell` helper next to Maziar's own executable (in the .app or in `.build/<config>`).
    static var spellHelperURL: URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("MaziarSpell")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// A server left over from an earlier Maziar run. If Maziar is force-quit or crashes, its child process
    /// isn't stopped with it — without this, every relaunch would add another server on another port.
    /// The pid is recorded at launch; before starting a new server, one still alive under that pid (and
    /// really running Numenor's backend, not an unrelated process that reused the number) is stopped.
    private func stopStaleServer() {
        Self.stopServer(recordedIn: pidFile)
    }

    /// Stops the backend whose pid is recorded in `file` (if it's still alive and really is the editor's
    /// backend, not an unrelated process that reused the number), then removes the file.
    nonisolated private static func stopServer(recordedIn file: URL) {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let command = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard command.contains("apps/backend/src/index.js") else { return }
        kill(pid, SIGTERM)
        // Give it a moment to exit so nothing writes into the old folder while it's being moved.
        for _ in 0..<20 where kill(pid, 0) == 0 { usleep(100_000) }
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: appDirectory.appendingPathComponent("apps/frontend/dist/index.html").path)
            && fm.fileExists(atPath: appDirectory.appendingPathComponent("node_modules").path)
    }

    private init() {
        state = isInstalled ? .stopped : .notInstalled
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NumenorServer.shared.terminateProcess() }
        }
    }

    // MARK: - Moving over from Numenor

    /// Where the editor lived when it was still OpenPrism (cloned from upstream and patched).
    nonisolated static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar/OpenPrism", isDirectory: true)
    }

    /// One-time move from `…/Maziar/OpenPrism` into `base`: any server still running from there is stopped,
    /// the projects and sync backups are kept, the already downloaded node_modules are reused (saves a long first `npm install`), and the old
    /// checkout is removed. Runs from `DriveNumenorSync.baseDirectory`, i.e. before anything — the server or
    /// Google Drive sync — touches the new folder.
    nonisolated static func migrateLegacyFolder(into base: URL) {
        let fm = FileManager.default
        let legacy = legacyDirectory
        // Never "migrate" the new folder into itself.
        guard fm.fileExists(atPath: legacy.path), legacy.standardizedFileURL != base.standardizedFileURL else { return }
        // A server still running from the old checkout (e.g. after a force-quit) would keep writing there.
        stopServer(recordedIn: legacy.appendingPathComponent("server.pid"))
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["data", "sync-backups"] {
            let from = legacy.appendingPathComponent(name)
            let to = base.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        }
        let oldModules = legacy.appendingPathComponent("repo/node_modules")
        let newModules = base.appendingPathComponent("app/node_modules")
        if fm.fileExists(atPath: oldModules.path), !fm.fileExists(atPath: newModules.path) {
            try? fm.createDirectory(at: newModules.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldModules, to: newModules)
        }
        // Only remove the old folder once the projects are safely in the new place.
        guard !fm.fileExists(atPath: legacy.appendingPathComponent("data").path) else { return }
        try? fm.removeItem(at: legacy.appendingPathComponent("repo"))
        if (try? fm.contentsOfDirectory(atPath: legacy.path))?.allSatisfy({ $0 == ".DS_Store" }) ?? false {
            try? fm.removeItem(at: legacy)
        }
    }

    // MARK: - Public actions

    func setAI(_ config: AIConfig?) {
        guard config != aiConfig else { return }
        aiConfig = config
        if case .running = state { restart() }
    }

    /// Starts the server if Numenor is set up and nothing is running or starting yet.
    func startIfNeeded() {
        guard isInstalled else {
            // Packages already downloaded (an earlier install, or one moved over from OpenPrism): just finish
            // setting up instead of asking. A brand-new install waits for the "Set Up Numenor" button.
            if FileManager.default.fileExists(atPath: appDirectory.appendingPathComponent("node_modules").path), !isWorking {
                install()
            } else if !isWorking {
                state = .notInstalled
            }
            return
        }
        switch state {
        case .stopped, .failed: start()
        default: break
        }
    }

    func start() {
        guard !starting, process == nil else { return }
        guard isInstalled else { state = .notInstalled; return }
        starting = true
        state = .starting
        Task {
            defer { starting = false }
            await launch()
        }
    }

    func stop() {
        terminateProcess()
        if isInstalled { state = .stopped }
    }

    func restart() {
        terminateProcess()
        starting = false
        start()
    }

    /// First-time setup: copy the bundled source, install dependencies and build the UI, then start.
    func install() {
        guard !isWorking else { return }
        Task {
            log = ""
            do {
                try await setUpIfNeeded(force: false)
                state = .stopped
                start()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Sets Numenor up again from the bundled source (fresh copy, dependencies checked, rebuilt), then restarts.
    func rebuild() {
        guard !isWorking else { return }
        terminateProcess()
        Task {
            log = ""
            do {
                try await setUpIfNeeded(force: true)
                state = .stopped
                start()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    // MARK: - Setup

    /// A digest of every file in the bundled source, so a changed Numenor (new Maziar build) is noticed.
    private static func digest(of directory: URL, only file: String? = nil) -> String? {
        let fm = FileManager.default
        var hasher = SHA256()
        if let file {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
            hasher.update(data: data)
        } else {
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
            var paths: [String] = []
            for case let url as URL in walker {
                let rel = String(url.path.dropFirst(directory.path.count))
                if rel.contains("/node_modules") || rel.contains("/dist/") || rel.hasSuffix(".DS_Store") {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { paths.append(rel) }
            }
            for rel in paths.sorted() {
                hasher.update(data: Data(rel.utf8))
                if let data = try? Data(contentsOf: directory.appendingPathComponent(rel)) { hasher.update(data: data) }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Brings the set-up copy in line with the bundled source. A no-op (apart from hashing ~3 MB) when
    /// nothing changed; otherwise copies, runs `npm install` if the lockfile changed, and rebuilds.
    private func setUpIfNeeded(force: Bool) async throws {
        guard let source = Self.bundledSource, let wanted = Self.digest(of: source) else {
            throw SetupError("Numenor's files are missing from this copy of Maziar. Rebuild Maziar (./build_app.sh release).")
        }
        let current = (try? String(contentsOf: sourceMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, current == wanted, isInstalled { return }

        state = .working("Checking for Node.js\u{2026}")
        try await requireTool("node", help: "Node.js 18 or newer is required. Install it from nodejs.org (or `brew install node`), then try again.")
        try await requireTool("npm", help: "npm was not found. It comes with Node.js — install it from nodejs.org, then try again.")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        state = .working("Copying Numenor\u{2026}")
        // --delete removes files dropped from Numenor; dependencies, the build output and markers stay.
        try await shell(
            "/usr/bin/rsync -a --delete --exclude node_modules --exclude apps/frontend/dist --exclude '.maziar-*' --exclude .DS_Store "
                + "\(shellQuote(source.path + "/")) \(shellQuote(appDirectory.path + "/"))",
            cwd: nil)

        let lock = Self.digest(of: appDirectory, only: "package-lock.json") ?? ""
        let installedLock = (try? String(contentsOf: lockMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modulesExist = FileManager.default.fileExists(atPath: appDirectory.appendingPathComponent("node_modules").path)
        if force || !modulesExist || installedLock != lock {
            state = .working("Installing dependencies (a few minutes the first time)\u{2026}")
            try await shell("npm install --no-audit --no-fund", cwd: appDirectory)
            try? lock.write(to: lockMarker, atomically: true, encoding: .utf8)
        }

        state = .working("Building the Numenor interface\u{2026}")
        try await shell("npm run build", cwd: appDirectory)
        guard isInstalled else { throw SetupError("The build finished but the interface files are missing.") }
        try? wanted.write(to: sourceMarker, atomically: true, encoding: .utf8)
    }

    // MARK: - Launch

    private func launch() async {
        do {
            try await setUpIfNeeded(force: false)
            state = .starting
            stopStaleServer()
            guard let port = Self.freePort() else { throw SetupError("No free local port was found.") }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "exec node apps/backend/src/index.js"]
            process.currentDirectoryURL = appDirectory
            var env = Self.environment()
            env["PORT"] = String(port)
            env["NUMENOR_DATA_DIR"] = dataDirectory.path
            // Only this Mac can reach the editor — nobody else on the network.
            env["NUMENOR_HOST"] = "127.0.0.1"
            // Numenor then ignores any AI settings its own page sends and uses only the values below (or
            // fails with "key not set" when Maziar has none).
            // Spelling/grammar for the editor through macOS's checker (see Sources/MaziarSpell).
            if let helper = Self.spellHelperURL { env["MAZIAR_SPELL_HELPER"] = helper.path }
            for key in env.keys where key.hasPrefix("OPENPRISM_") || key.hasPrefix("NUMENOR_LLM_") { env.removeValue(forKey: key) }
            env["NUMENOR_LLM_LOCKED"] = "1"
            if let ai = aiConfig {
                env["NUMENOR_LLM_ENDPOINT"] = ai.endpoint
                env["NUMENOR_LLM_API_KEY"] = ai.apiKey
                env["NUMENOR_LLM_MODEL"] = ai.model
            }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.append(text) }
            }
            stopRequested = false
            process.terminationHandler = { [weak self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in self?.processEnded(proc) }
            }
            try process.run()
            self.process = process
            try? "\(process.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

            let url = URL(string: "http://127.0.0.1:\(port)/")!
            if await waitUntilHealthy(port: port) {
                if self.process === process { state = .running(url) }
            } else if self.process === process {
                terminateProcess()
                state = .failed("Numenor did not start. See the log below.")
            }
        } catch {
            process = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func processEnded(_ proc: Process) {
        guard process === proc else { return }
        process = nil
        if stopRequested { return }
        state = .failed("Numenor stopped unexpectedly (exit code \(proc.terminationStatus)). See the log below.")
    }

    private func terminateProcess() {
        stopRequested = true
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func waitUntilHealthy(port: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/api/health")!
        for _ in 0..<60 {
            if process?.isRunning != true { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - Shell helpers

    private struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// A GUI app inherits a bare PATH, so Homebrew's and TeX's folders are added explicitly — `node`,
    /// `npm`, and the `latexmk`/`synctex`/`tectonic` Numenor compiles with all live there.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/Library/TeX/texbin"]
        let existing = env["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]
        env["PATH"] = (extra + existing).joined(separator: ":")
        return env
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func requireTool(_ name: String, help: String) async throws {
        do { try await shell("command -v \(name)", cwd: nil, logOutput: false) }
        catch { throw SetupError(help) }
    }

    private func shell(_ command: String, cwd: URL?, logOutput: Bool = true) async throws {
        if logOutput { append("$ \(command)\n") }
        let environment = Self.environment()
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = cwd
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard logOutput, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.append(text) }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: -1)
            }
        }
        guard status == 0 else { throw SetupError("`\(command.prefix(60))` failed (exit code \(status)). See the log below.") }
    }

    private func append(_ text: String) {
        log += text
        if log.count > 30_000 { log = String(log.suffix(24_000)) }
    }

    /// The first unused TCP port from 8787 (Numenor's own default) upward, checked by binding to it.
    private static func freePort() -> Int? {
        for port in 8787...8830 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return port }
        }
        return nil
    }
}
