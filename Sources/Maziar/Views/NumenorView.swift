import SwiftUI
import WebKit

/// The second editor: Numenor (github.com/farhadsh1992/numenor, based on OpenPrism) running locally and embedded here.
/// `NumenorServer` installs and runs it; this page shows setup/progress/errors until the server is
/// up, then the Numenor web UI itself inside Maziar's embedded browser. `ContentView` keeps the page
/// mounted after the first visit so switching sidebar sections doesn't reload the editor.
struct NumenorView: View {
    @ObservedObject private var server = NumenorServer.shared
    @EnvironmentObject private var texManager: TeXInstallationManager
    @State private var attemptedMacTeXSetup = false

    var body: some View {
        Group {
            switch server.state {
            case .running(let url):
                VStack(spacing: 0) {
                    macTeXSetupStatus
                    NumenorBrowser(url: url, server: server)
                        .id(url)
                }
                .onAppear(perform: installMacTeXIfNeeded)
            case .notInstalled:
                setupCard(
                    icon: "square.and.arrow.down",
                    title: "Numenor",
                    message: "Numenor is a LaTeX editor with an AI writing assistant, live PDF preview, SyncTeX and journal templates. It runs on this Mac and opens right here as a second editor next to Maziar's own.\n\nIt comes with Maziar \u{2014} setting it up installs its packages and builds it (a few minutes, once). It needs Node.js 18+. If the TeX Live compilers are missing, Maziar automatically downloads MacTeX and macOS asks you to authorize its installation.",
                    buttonTitle: "Set Up Numenor",
                    action: { server.install() }
                )
            case .working(let step):
                progress(step)
            case .starting:
                progress("Starting Numenor…")
            case .stopped:
                setupCard(
                    icon: "play.circle",
                    title: "Numenor is stopped",
                    message: "Start the local Numenor server to open the editor.",
                    buttonTitle: "Start Numenor",
                    action: { server.start() }
                )
            case .failed(let message):
                failure(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { server.startIfNeeded() }
    }

    private func installMacTeXIfNeeded() {
        guard !attemptedMacTeXSetup, !texManager.isInstalling, !NumenorServer.hasTeXLiveCompilers else { return }
        attemptedMacTeXSetup = true
        texManager.install(.mactex)
    }

    @ViewBuilder private var macTeXSetupStatus: some View {
        if attemptedMacTeXSetup && !NumenorServer.hasTeXLiveCompilers {
            HStack(spacing: 10) {
                if texManager.isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Setting up MacTeX. The download can take a while. macOS will ask for administrator authorization.")
                } else {
                    Text(texManager.installError ?? "MacTeX installation finished, but Numenor still can't find its compilers.")
                    Button("Retry MacTeX installation") { texManager.install(.mactex) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(.quaternary)
        }
    }

    private func setupCard(icon: String, title: String, message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }

    private func progress(_ step: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(step).font(.headline)
            logView.frame(maxWidth: 640, maxHeight: 260)
        }
        .padding(32)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.orange)
            Text("Numenor couldn't start").font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack {
                Button(server.isInstalled ? "Try again" : "Set up again") {
                    server.isInstalled ? server.start() : server.install()
                }
                .buttonStyle(.borderedProminent)
                if server.isInstalled {
                    Button("Rebuild") { server.rebuild() }
                }
            }
            logView.frame(maxWidth: 640, maxHeight: 240)
        }
        .padding(32)
    }

    private var logView: some View {
        ScrollView {
            Text(server.log.isEmpty ? "No output yet." : server.log)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Light / dark choice for the embedded Numenor page. Numenor ships light-only (its code editor's
/// colors are fixed in its source), so Maziar adds the dark look itself: a stylesheet injected into the
/// page that inverts its colors, with images, PDF pages and figures flipped back so they look normal.
/// `auto` follows Maziar's own appearance.
enum NumenorTheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Match Maziar"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Runs before Numenor's own scripts on every load (and live when the theme changes): presets
    /// English once, then switches the dark stylesheet on or off.
    static let greetingKey = "maziar.openPrism.greeting"
    static let defaultGreeting = "Welcome to Numenor"

    /// Spelling and grammar language for the Numenor editor (macOS checker codes). American by default.
    static let spellLanguageKey = "maziar.openPrism.spellLanguage"
    static let defaultSpellLanguage = "en_US"
    static let spellLanguages: [(code: String, name: String)] = [("en_US", "English (US)"), ("en_GB", "English (UK)")]

    /// `text` as a JavaScript string literal (JSON, wrapped in an array so a bare string encodes fine).
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return "(\(json))[0]"
    }

    static func pageScript(dark: Bool, popOut: Bool, greeting: String, spellLanguage: String = defaultSpellLanguage) -> String {
        """
        (function () {
          try { if (!localStorage.getItem('numenor-lang')) localStorage.setItem('numenor-lang', 'en-US'); } catch (e) {}
          // Spelling/grammar language from Maziar's Settings; the editor reads it on load and listens for changes.
          window.__maziarSpellLanguage = \(jsString(spellLanguage));
          try { window.dispatchEvent(new CustomEvent('maziar-spell-language', { detail: window.__maziarSpellLanguage })); } catch (e) {}
          var root = document.documentElement;
          // Numenor has its own light and dark themes: tell it which one Maziar is showing (no colour
          // inversion any more). Transitions pause for a moment so the switch doesn't flicker.
          root.classList.remove('maziar-dark');
          root.classList.add('nm-theme-switching');
          root.setAttribute('data-theme', \(dark ? "'dark'" : "'light'"));
          requestAnimationFrame(function () { requestAnimationFrame(function () { root.classList.remove('nm-theme-switching'); }); });

          // Opening a project is a client-side route change to /editor/<id>. When pop-out is on, turn that
          // into window.open() so the project gets its own Maziar window and the project list stays put.
          // Pages that are themselves popups (window.opener set) navigate normally, and if the window can't
          // be opened (no user gesture, e.g. right after "create project") it falls back to in-page.
          // Start-page title: Numenor builds its title letter by letter, so rather than fight its
          // re-renders the original heading is hidden and a same-styled one with the greeting sits next to it.
          // Empty text restores Numenor's own heading.
          window.__maziarGreeting = \(jsString(greeting));
          if (!window.__maziarGreetingInstalled) {
            window.__maziarGreetingInstalled = true;
            window.__maziarSyncGreeting = function () {
              var text = window.__maziarGreeting;
              var original = document.querySelector('h1.landing-title:not([data-maziar])');
              var mine = document.querySelector('h1[data-maziar]');
              if (!text) {
                if (mine) mine.remove();
                if (original) original.style.display = '';
                return;
              }
              if (!original) return;
              original.style.display = 'none';
              if (mine && mine.dataset.maziar === text) return;
              if (mine) mine.remove();
              mine = document.createElement('h1');
              mine.className = 'landing-title';
              mine.dataset.maziar = text;
              var space = text.indexOf(' ');
              var accentLength = space < 0 ? text.length : space;
              var spans = Array.from(text).map(function (ch, i) {
                var span = document.createElement('span');
                span.className = i < accentLength ? 'landing-title-accent' : 'landing-title-dark';
                span.style.opacity = '0';
                span.style.transition = 'opacity 0.15s ease';
                span.textContent = ch;
                mine.appendChild(span);
                return span;
              });
              var cursor = document.createElement('span');
              cursor.className = 'landing-cursor';
              mine.appendChild(cursor);
              original.insertAdjacentElement('afterend', mine);
              spans.forEach(function (span, i) { setTimeout(function () { span.style.opacity = '1'; }, 70 * (i + 1)); });
            };
            new MutationObserver(function () { window.__maziarSyncGreeting(); })
              .observe(document.documentElement, { childList: true, subtree: true });
          }
          window.__maziarSyncGreeting();

          window.__maziarPopOut = \(popOut ? "true" : "false");
          if (!window.__maziarPatched) {
            window.__maziarPatched = true;
            var originalPush = history.pushState.bind(history);
            history.pushState = function (state, title, url) {
              try {
                if (window.__maziarPopOut && !window.opener && url != null) {
                  var target = new URL(url, location.href);
                  if (/^\\/editor\\//.test(target.pathname) && window.open(target.href, '_blank')) return;
                }
              } catch (e) {}
              return originalPush(state, title, url);
            };
          }
        })();
        """
    }
}

/// The running editor: a small toolbar over the embedded Numenor page.
private struct NumenorBrowser: View {
    let url: URL
    @ObservedObject var server: NumenorServer

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @State private var showLog = false
    @AppStorage("maziar.openPrism.theme") private var themeRaw = NumenorTheme.auto.rawValue
    @AppStorage("maziar.openPrism.popOutProjects") private var popOutProjects = true
    @AppStorage(NumenorTheme.greetingKey) private var greeting = NumenorTheme.defaultGreeting
    @AppStorage(NumenorTheme.spellLanguageKey) private var spellLanguage = NumenorTheme.defaultSpellLanguage
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var webViewHolder = WebViewHolder()

    private var theme: NumenorTheme { NumenorTheme(rawValue: themeRaw) ?? .auto }
    private var isDark: Bool {
        switch theme {
        case .auto: return colorScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    /// Pick a new home for all Numenor projects — e.g. a folder in Google Drive, so Google Drive for desktop
    /// keeps them synced — and move them there.
    private func chooseProjectsFolder(move: Bool) {
        let panel = NSOpenPanel()
        panel.title = move ? "Move Numenor projects" : "Use a Numenor projects folder"
        panel.message = move
            ? "Choose an empty folder for your Numenor projects. A folder inside Google Drive keeps them synced by Google Drive."
            : "Choose the folder that already holds your Numenor projects (e.g. the Google Drive folder your other Mac uses). Nothing is moved."
        panel.prompt = move ? "Move Here" : "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if let drive = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path))?.first(where: { $0.hasPrefix("GoogleDrive-") }) {
            panel.directoryURL = cloud.appendingPathComponent(drive).appendingPathComponent("My Drive")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if move { server.moveProjectsFolder(to: url) } else { server.useProjectsFolder(url) }
    }

    private func applyPageSettings() {
        guard let view = webViewHolder.view else { return }
        let script = NumenorTheme.pageScript(dark: isDark, popOut: popOutProjects, greeting: greeting, spellLanguage: spellLanguage)
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view.evaluateJavaScript(script)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { webViewHolder.view?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { webViewHolder.view?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                Button { webViewHolder.view?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { webViewHolder.view?.load(URLRequest(url: url)) } label: { Image(systemName: "house") }
                Text("Numenor · localhost:\(url.port ?? 0)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                if server.share.active {
                    Menu {
                        Text("Shared through \(server.share.provider)")
                        Text(server.share.url)
                        Divider()
                        Text("Invite people from a project\u{2019}s Collab tab (\u{201c}Share this project\u{201d}).")
                        Button("Stop sharing") { server.stopSharing() }
                    } label: {
                        Label("Sharing", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("A project is shared — invited people can edit it while Numenor runs. Click to stop.")
                }
                Menu {
                    Picker("Appearance", selection: $themeRaw) {
                        ForEach(NumenorTheme.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: isDark ? "moon.fill" : "sun.max")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Light or dark")
                Menu {
                    Toggle("Open projects in a separate window", isOn: $popOutProjects)
                    Divider()
                    Text("Projects folder: \(server.dataDirectory.path)")
                    Button("Move projects folder\u{2026}") { chooseProjectsFolder(move: true) }
                    Button("Use an existing projects folder\u{2026}") { chooseProjectsFolder(move: false) }
                    if server.dataDirectory.standardizedFileURL.path != DriveNumenorSync.defaultDataDirectory.standardizedFileURL.path {
                        Button("Move projects back to this Mac") { server.moveProjectsFolder(to: DriveNumenorSync.defaultDataDirectory) }
                    }
                    Button("Show projects folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([server.dataDirectory]) }
                    Divider()
                    if server.share.active {
                        Button("Stop sharing") { server.stopSharing() }
                    } else {
                        Text("To share a project: open it \u{2192} Collab tab \u{2192} Share this project")
                    }
                    Divider()
                    Button("Restart server") { server.restart() }
                    Button("Rebuild Numenor") { server.rebuild() }
                        .help("Set Numenor up again from the copy that ships with this Maziar (it updates by itself when Maziar does).")
                    Button("Stop server") { server.stop() }
                    Divider()
                    Button("Show server log") { showLog = true }
                    Button("Open in Safari") { NSWorkspace.shared.open(currentURL ?? url) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            ScholarBrowserView(
                initialURL: url,
                onViewCreated: { webViewHolder.view = $0 },
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL,
                documentStartScript: NumenorTheme.pageScript(dark: isDark, popOut: popOutProjects, greeting: greeting, spellLanguage: spellLanguage)
            )
        }
        .onChange(of: isDark) { _, _ in applyPageSettings() }
        .onChange(of: popOutProjects) { _, _ in applyPageSettings() }
        .onChange(of: greeting) { _, _ in applyPageSettings() }
        .onChange(of: spellLanguage) { _, _ in applyPageSettings() }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Numenor server log").font(.headline)
                ScrollView {
                    Text(server.log.isEmpty ? "No output yet." : server.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { showLog = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(16)
            .frame(width: 640, height: 420)
        }
    }
}
