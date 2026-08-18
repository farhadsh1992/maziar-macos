import Foundation

/// Compiles a project's main .tex file to PDF using a locally installed
/// TeX distribution (TinyTeX or MacTeX), via `latexmk` when available
/// (handles multi-pass reference/citation resolution) or two `pdflatex`
/// passes otherwise. When compiling against TinyTeX (which ships a curated,
/// minimal package set rather than the full TeX Live archive), missing
/// packages are detected from the log and installed automatically via
/// `tlmgr`, then compilation is retried — mirroring what the official
/// `tinytex` R package does.
enum SystemLaTeXCompiler {
    struct CompileOutput {
        let pdf: Data
        let log: String
        let succeeded: Bool
    }

    enum CompileError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    private static let maxPackageInstallAttempts = 8

    static func compile(
        pdflatexURL: URL,
        projectDirectory: URL,
        mainFile: String,
        engine: LaTeXEngine = .pdflatex,
        extraFlags: String = ""
    ) async throws -> CompileOutput {
        try await Task.detached(priority: .userInitiated) {
            try runCompile(
                pdflatexURL: pdflatexURL, projectDirectory: projectDirectory, mainFile: mainFile,
                engine: engine, extraFlags: extraFlags
            )
        }.value
    }

    private static func runCompile(
        pdflatexURL: URL, projectDirectory: URL, mainFile: String, engine: LaTeXEngine, extraFlags: String
    ) throws -> CompileOutput {
        let fm = FileManager.default
        let binDir = pdflatexURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        let latexmkURL = binDir.appendingPathComponent("latexmk")
        let tlmgrURL = binDir.appendingPathComponent("tlmgr")
        let useLatexmk = fm.fileExists(atPath: latexmkURL.path)
        let canAutoInstall = fm.fileExists(atPath: tlmgrURL.path)
        let extraArgs = extraFlags.split(separator: " ").map(String.init)
        // Fallback path (no latexmk) uses the engine's own binary directly, alongside pdflatex.
        let rawEngineURL = binDir.appendingPathComponent(engine.rawValue)
        let engineURL = fm.fileExists(atPath: rawEngineURL.path) ? rawEngineURL : pdflatexURL

        var combinedLog = ""
        var succeeded = false
        var triedPackages = Set<String>()

        for attempt in 0..<maxPackageInstallAttempts {
            if useLatexmk {
                let result = run(
                    executable: latexmkURL,
                    arguments: [engine.latexmkFlag, "-g", "-synctex=1", "-interaction=nonstopmode", "-halt-on-error"]
                        + extraArgs + [mainFile],
                    directory: projectDirectory,
                    environment: env
                )
                combinedLog += (attempt > 0 ? "\n----- retrying after installing a missing package -----\n" : "") + result.output
                succeeded = result.exitCode == 0
            } else {
                let first = run(
                    executable: engineURL,
                    arguments: ["-synctex=1", "-interaction=nonstopmode", "-halt-on-error"] + extraArgs + [mainFile],
                    directory: projectDirectory,
                    environment: env
                )
                combinedLog += (attempt > 0 ? "\n----- retrying after installing a missing package -----\n" : "") + first.output
                let second = run(
                    executable: engineURL,
                    arguments: ["-synctex=1", "-interaction=nonstopmode", "-halt-on-error"] + extraArgs + [mainFile],
                    directory: projectDirectory,
                    environment: env
                )
                combinedLog += "\n" + second.output
                succeeded = second.exitCode == 0
            }

            if succeeded { break }
            guard canAutoInstall,
                  let missingFile = Self.missingFileName(in: combinedLog),
                  !triedPackages.contains(missingFile) else { break }
            triedPackages.insert(missingFile)

            guard let packageName = Self.resolvePackage(forMissingFile: missingFile, tlmgrURL: tlmgrURL, environment: env) else {
                combinedLog += "\nCould not find a package that provides '\(missingFile)'.\n"
                break
            }
            combinedLog += "\nInstalling missing package '\(packageName)' (provides \(missingFile))...\n"
            let installResult = run(
                executable: tlmgrURL, arguments: ["install", packageName], directory: projectDirectory, environment: env
            )
            combinedLog += installResult.output
            guard installResult.exitCode == 0 else { break }
        }

        let pdfName = (mainFile as NSString).deletingPathExtension + ".pdf"
        let pdfURL = projectDirectory.appendingPathComponent(pdfName)
        guard let pdfData = try? Data(contentsOf: pdfURL) else {
            throw CompileError.message(combinedLog.isEmpty ? "Compilation failed; no PDF was produced." : combinedLog)
        }
        return CompileOutput(pdf: pdfData, log: combinedLog, succeeded: succeeded)
    }

    /// Parses a pdfTeX log for "File `foo.sty' not found." and returns "foo.sty".
    private static func missingFileName(in log: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "File `([^']+)' not found") else { return nil }
        let range = NSRange(log.startIndex..., in: log)
        guard let match = regex.firstMatch(in: log, range: range),
              let matchRange = Range(match.range(at: 1), in: log) else { return nil }
        return String(log[matchRange])
    }

    /// Resolves the TeX Live package name that provides a given file, via `tlmgr search --file`.
    private static func resolvePackage(forMissingFile file: String, tlmgrURL: URL, environment: [String: String]) -> String? {
        let result = run(
            executable: tlmgrURL,
            arguments: ["search", "--global", "--file", "/\(file)"],
            directory: FileManager.default.temporaryDirectory,
            environment: environment
        )
        for line in result.output.split(separator: "\n") {
            if line.hasSuffix(":") {
                return String(line.dropLast())
            }
        }
        return nil
    }

    private static func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String]
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ("Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)", -1)
        }
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: outputData, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
