import Foundation

enum TeXDistribution: String, CaseIterable, Identifiable, Codable {
    case tinytex
    case mactex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinytex: return "TinyTeX"
        case .mactex: return "MacTeX"
        }
    }

    var sizeHint: String {
        switch self {
        case .tinytex: return "~200 MB download, lightweight"
        case .mactex: return "~6\u{2013}7 GB download, full TeX Live"
        }
    }
}

/// The TeX engine latexmk drives. New engines just need a case here and a `latexmkFlag`.
enum LaTeXEngine: String, CaseIterable, Identifiable, Codable {
    case pdflatex
    case xelatex
    case lualatex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdflatex: return "pdfLaTeX"
        case .xelatex: return "XeLaTeX"
        case .lualatex: return "LuaLaTeX"
        }
    }

    /// The latexmk flag that selects this engine (pdfLaTeX is latexmk's default via `-pdf`).
    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex: return "-xelatex"
        case .lualatex: return "-lualatex"
        }
    }
}

/// Detects, and installs on request, a local TeX distribution used to
/// compile LaTeX projects via `pdflatex`/`latexmk`.
///
/// This also holds the general compiler preferences (engine, auto-compile,
/// extra flags) — adding another one later is just: a new `@Published`
/// property here (persisted the same way as the others in `init`/`didSet`),
/// and a row for it in `LaTeXCompilerSettingsTab` in SettingsView.swift.
@MainActor
final class TeXInstallationManager: ObservableObject {
    // Trivial placeholder defaults — `init()` immediately overwrites them via
    // `loadAllFromDefaults()`; see the same pattern/reasoning in AISettings.swift.
    @Published var selectedDistribution: TeXDistribution = .tinytex {
        didSet { UserDefaults.standard.set(selectedDistribution.rawValue, forKey: Self.prefKey) }
    }
    @Published var engine: LaTeXEngine = .pdflatex {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey) }
    }
    @Published var autoCompileOnSave: Bool = false {
        didSet { UserDefaults.standard.set(autoCompileOnSave, forKey: Self.autoCompileKey) }
    }
    @Published var extraCompilerFlags: String = "" {
        didSet { UserDefaults.standard.set(extraCompilerFlags, forKey: Self.extraFlagsKey) }
    }
    @Published var isInstalling = false
    @Published var installLog = ""
    @Published var installError: String?

    private static let prefKey = "maziar.texDistribution"
    private static let engineKey = "maziar.latexEngine"
    private static let autoCompileKey = "maziar.autoCompileOnSave"
    private static let extraFlagsKey = "maziar.extraCompilerFlags"

    init() {
        loadAllFromDefaults()
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        loadAllFromDefaults()
    }

    private func loadAllFromDefaults() {
        if let raw = UserDefaults.standard.string(forKey: Self.prefKey),
           let distro = TeXDistribution(rawValue: raw) {
            selectedDistribution = distro
        } else {
            selectedDistribution = .tinytex
        }

        if let raw = UserDefaults.standard.string(forKey: Self.engineKey), let engine = LaTeXEngine(rawValue: raw) {
            self.engine = engine
        } else {
            self.engine = .pdflatex
        }

        autoCompileOnSave = UserDefaults.standard.bool(forKey: Self.autoCompileKey)
        extraCompilerFlags = UserDefaults.standard.string(forKey: Self.extraFlagsKey) ?? ""
    }

    func isInstalled(_ distro: TeXDistribution) -> Bool {
        pdflatexURL(for: distro) != nil
    }

    /// Resolves the `pdflatex` binary for the currently selected distribution (or a specific one).
    func pdflatexURL(for distro: TeXDistribution? = nil) -> URL? {
        switch distro ?? selectedDistribution {
        case .mactex:
            let path = "/Library/TeX/texbin/pdflatex"
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        case .tinytex:
            let binRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/TinyTeX/bin", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: binRoot, includingPropertiesForKeys: nil
            ) else { return nil }
            for entry in entries {
                let candidate = entry.appendingPathComponent("pdflatex")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    func install(_ distro: TeXDistribution) {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ""
        installError = nil

        Task {
            switch distro {
            case .tinytex:
                let ok = await runStreaming(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", Self.tinytexInstallCommand])
                if !ok { installError = "Installation exited with an error. See the log for details." }
            case .mactex:
                await installMacTeX()
            }
            isInstalling = false
        }
    }

    /// MacTeX ships as a .pkg, whose installer needs admin rights. Homebrew's cask installer
    /// runs it via plain `sudo`, which fails with no error dialog when there's no TTY (the
    /// exact case here, since we're a background process spawned from a GUI app) — and simply
    /// wrapping the *whole* `brew install` in an admin-privileged shell doesn't work either,
    /// since Homebrew refuses to run as root. So this downloads unprivileged via `brew fetch`
    /// (no root needed) and then elevates *only* the `installer` invocation via a native macOS
    /// authorization dialog.
    private func installMacTeX() async {
        guard let brew = Self.locateBrew() else {
            installError = "Homebrew is required to install MacTeX. Install it from https://brew.sh, then try again."
            return
        }

        installLog += "Downloading MacTeX (several GB \u{2014} this can take a while)...\n"
        let fetchOK = await runStreaming(executable: brew, arguments: ["fetch", "--cask", "mactex-no-gui"])
        guard fetchOK else {
            installError = "Download failed. See the log for details."
            return
        }

        let cacheResult = await runCapture(executable: brew, arguments: ["--cache", "--cask", "mactex-no-gui"])
        let pkgPath = cacheResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cacheResult.exitCode == 0, !pkgPath.isEmpty, FileManager.default.fileExists(atPath: pkgPath) else {
            installError = "Could not locate the downloaded MacTeX package."
            return
        }

        installLog += "\nRequesting administrator authorization to install the package...\n"
        let installerCommand = "/usr/sbin/installer -pkg \"\(pkgPath)\" -target /"
        let escaped = installerCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let installOK = await runStreaming(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
        if !installOK {
            installError = "Installer failed or was cancelled. See the log for details."
        }
    }

    private static let tinytexInstallCommand =
        "sh -c \"$(curl -fsSL https://raw.githubusercontent.com/rstudio/tinytex/main/tools/install-bin-unix.sh)\""

    private static func locateBrew() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Runs a process, streaming its combined output live into `installLog`. Returns whether it exited 0.
    @discardableResult
    private func runStreaming(executable: URL, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.installLog += text }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    self?.installLog += "Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)\n"
                }
                continuation.resume(returning: false)
            }
        }
    }

    /// Runs a process and returns its full output + exit code, without touching `installLog`.
    private func runCapture(executable: URL, arguments: [String]) async -> (output: String, exitCode: Int32) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return ("", Int32(-1))
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        }.value
    }
}
