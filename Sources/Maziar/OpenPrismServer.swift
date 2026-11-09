import Foundation
import AppKit
import Darwin

/// Runs OpenPrism (github.com/OpenDCAI/OpenPrism, MIT) — an open-source LaTeX + AI writing workspace —
/// as a local server so Maziar can embed its web UI as a second editor.
///
/// OpenPrism is a Node.js app (React frontend, Fastify backend), not something that can be linked into a
/// Swift binary, so Maziar manages it as a child process instead:
///   1. **Install** — `git clone` into `~/Library/Application Support/Maziar/OpenPrism/repo`, then
///      `npm install` and `npm run build` (needs git and Node.js 18+ on this Mac).
///   2. **Start** — `node apps/backend/src/index.js` on a free localhost port. With the frontend built, that
///      one process serves both the UI and the API.
///   3. **Stop** — when the app quits (or from the page's toolbar).
///
/// OpenPrism's own projects live in `…/Maziar/OpenPrism/data` (via `OPENPRISM_DATA_DIR`), outside the
/// checkout, so updating the checkout never touches them. They are plain files on this Mac; when Google
/// Drive sync is on, `DriveOpenPrismSync` keeps them in step with the other Mac.
@MainActor
final class OpenPrismServer: ObservableObject {
    static let shared = OpenPrismServer()

    enum State: Equatable {
        case notInstalled
        /// Installing or updating — the string is the current step, shown above the log.
        case working(String)
        case stopped
        case starting
        case running(URL)
        case failed(String)
    }

    /// The AI OpenPrism talks to — Maziar's own provider, model and key (Settings \u{2192} AI), handed to the
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
    /// Output of the install/update steps and of the server itself (last ~30 000 characters).
    @Published private(set) var log = ""

    private var process: Process?
    private var stopRequested = false
    private var starting = false

    private static let repoURL = "https://github.com/OpenDCAI/OpenPrism"

    private var baseDirectory: URL { DriveOpenPrismSync.baseDirectory }
    private var repoDirectory: URL { baseDirectory.appendingPathComponent("repo", isDirectory: true) }
    private var dataDirectory: URL { baseDirectory.appendingPathComponent("data", isDirectory: true) }
    private var pidFile: URL { baseDirectory.appendingPathComponent("server.pid") }

    /// A server left over from an earlier Maziar run. If Maziar is force-quit or crashes, its child process
    /// isn't stopped with it — without this, every relaunch would add another server on another port.
    /// The pid is recorded at launch; before starting a new server, one still alive under that pid (and
    /// really running OpenPrism's backend, not an unrelated process that reused the number) is stopped.
    private func stopStaleServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0 else { try? FileManager.default.removeItem(at: pidFile); return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        if (try? ps.run()) != nil {
            ps.waitUntilExit()
            let command = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if command.contains("apps/backend/src/index.js") { kill(pid, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoDirectory.appendingPathComponent("apps/frontend/dist/index.html").path)
            && fm.fileExists(atPath: repoDirectory.appendingPathComponent("node_modules").path)
    }

    private init() {
        state = isInstalled ? .stopped : .notInstalled
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { OpenPrismServer.shared.terminateProcess() }
        }
    }

    // MARK: - Public actions

    func setAI(_ config: AIConfig?) {
        guard config != aiConfig else { return }
        aiConfig = config
        if case .running = state { restart() }
    }

    /// Starts the server if OpenPrism is installed and nothing is running or starting yet.
    func startIfNeeded() {
        guard isInstalled else { state = .notInstalled; return }
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

    /// First-time setup: clone, install dependencies and build the UI, then start.
    func install() {
        guard !isWorking else { return }
        Task { await runSetup(update: false) }
    }

    /// Pulls the latest OpenPrism, reinstalls dependencies, rebuilds, then restarts.
    func update() {
        guard !isWorking else { return }
        terminateProcess()
        Task { await runSetup(update: true) }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    // MARK: - Setup

    private func runSetup(update: Bool) async {
        log = ""
        do {
            state = .working("Checking for Node.js and git…")
            try await requireTool("node", help: "Node.js 18 or newer is required. Install it from nodejs.org (or `brew install node`), then try again.")
            try await requireTool("npm", help: "npm was not found. It comes with Node.js — install it from nodejs.org, then try again.")
            try await requireTool("git", help: "git was not found. Install the Xcode command line tools (`xcode-select --install`), then try again.")
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

            let repo = shellQuote(repoDirectory.path)
            if FileManager.default.fileExists(atPath: repoDirectory.appendingPathComponent(".git").path) {
                if update {
                    state = .working("Downloading the latest OpenPrism…")
                    // Drop the localhost patch (re-applied below) so the pull can't conflict with it.
                    try await shell("git -C \(repo) checkout -- . && git -C \(repo) pull --ff-only", cwd: nil)
                }
            } else {
                state = .working("Downloading OpenPrism…")
                try await shell("git clone --depth 1 \(Self.repoURL) \(repo)", cwd: nil)
            }
            try patchBackend()

            state = .working("Installing dependencies (a few minutes the first time)…")
            try await shell("npm install --no-audit --no-fund", cwd: repoDirectory)

            state = .working("Building the OpenPrism interface…")
            try await shell("npm run build", cwd: repoDirectory)

            guard isInstalled else { throw SetupError("The build finished but the interface files are missing.") }
            state = .stopped
            start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Two small edits to OpenPrism's backend, re-applied after every install/update/start (they're no-ops
    /// once present, and an update first discards them so `git pull` can't conflict):
    ///  1. It binds to every network interface (`0.0.0.0`). Maziar only needs this Mac to reach it, so it is
    ///     pinned to localhost — nobody else on the network can open the editor.
    ///  2. It normally prefers the endpoint/model/key typed into OpenPrism's own settings. When Maziar
    ///     launches it (`MAZIAR_LLM_LOCKED`), those are ignored so Maziar's AI settings are the only source.
    private func patchBackend() throws {
        let edits: [(file: String, find: String, replace: String)] = [
            ("apps/backend/src/index.js", "host: '0.0.0.0'", "host: '127.0.0.1'"),
            ("apps/backend/src/services/llmService.js",
             "export function resolveLLMConfig(llmConfig) {\n",
             "export function resolveLLMConfig(llmConfig) {\n  if (process.env.MAZIAR_LLM_LOCKED === '1') llmConfig = null; // Maziar\n"),
            ("apps/backend/src/services/llmService.js",
             "export async function callOpenAICompatible({ messages, model, endpoint, apiKey }) {\n",
             "export async function callOpenAICompatible({ messages, model, endpoint, apiKey }) {\n  if (process.env.MAZIAR_LLM_LOCKED === '1') { model = undefined; endpoint = undefined; apiKey = undefined; } // Maziar\n"),
        ]
        for edit in edits {
            let file = repoDirectory.appendingPathComponent(edit.file)
            guard var source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if source.contains(edit.replace) { continue }
            guard source.contains(edit.find) else {
                append("Note: couldn't patch \(edit.file) — OpenPrism may have changed upstream.\n")
                continue
            }
            source = source.replacingOccurrences(of: edit.find, with: edit.replace)
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Launch

    private func launch() async {
        do {
            try patchBackend()
            stopStaleServer()
            guard let port = Self.freePort() else { throw SetupError("No free local port was found.") }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "exec node apps/backend/src/index.js"]
            process.currentDirectoryURL = repoDirectory
            var env = Self.environment()
            env["PORT"] = String(port)
            env["OPENPRISM_DATA_DIR"] = dataDirectory.path
            // With this set, the patched backend ignores any AI settings OpenPrism's own page sends and
            // uses only the values below (or fails with "key not set" when Maziar has none).
            env["MAZIAR_LLM_LOCKED"] = "1"
            env.removeValue(forKey: "OPENPRISM_LLM_API_KEY")
            if let ai = aiConfig {
                env["OPENPRISM_LLM_ENDPOINT"] = ai.endpoint
                env["OPENPRISM_LLM_API_KEY"] = ai.apiKey
                env["OPENPRISM_LLM_MODEL"] = ai.model
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
                state = .failed("OpenPrism did not start. See the log below.")
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
        state = .failed("OpenPrism stopped unexpectedly (exit code \(proc.terminationStatus)). See the log below.")
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
    /// `npm`, and the `latexmk`/`tectonic` OpenPrism compiles with all live there.
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

    /// The first unused TCP port from 8787 (OpenPrism's own default) upward, checked by binding to it.
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
