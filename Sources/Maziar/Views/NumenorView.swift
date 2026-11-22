import SwiftUI
import WebKit

/// The second editor: Numenor (github.com/farhadsh1992/numenor, based on OpenPrism) running locally and embedded here.
/// `NumenorServer` installs and runs it; this page shows setup/progress/errors until the server is
/// up, then the Numenor web UI itself inside Maziar's embedded browser. `ContentView` keeps the page
/// mounted after the first visit so switching sidebar sections doesn't reload the editor.
struct NumenorView: View {
    @ObservedObject private var server = NumenorServer.shared
    @EnvironmentObject private var aiSettings: AISettings

    /// Hands Maziar's chosen AI (provider, model, key) to the server; restarts it only if that changed.
    private func syncAI() { server.setAI(aiSettings.numenorConfig()) }

    var body: some View {
        Group {
            switch server.state {
            case .running(let url):
                NumenorBrowser(url: url, server: server)
                    .id(url)
            case .notInstalled:
                setupCard(
                    icon: "square.and.arrow.down",
                    title: "Numenor",
                    message: "Numenor is a LaTeX editor with an AI writing assistant, live PDF preview, SyncTeX and journal templates. It runs on this Mac and opens right here as a second editor next to Maziar's own.\n\nIt comes with Maziar \u{2014} setting it up installs its packages and builds it (a few minutes, once). It needs Node.js 18+.",
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
        .onAppear {
            syncAI()
            server.startIfNeeded()
        }
        // Provider/model/URL edits publish; a key saved in Settings → AI doesn't, so also re-check whenever
        // a Maziar window (e.g. Settings, once closed) becomes key again.
        .onReceive(aiSettings.objectWillChange.receive(on: RunLoop.main)) { _ in syncAI() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in syncAI() }
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
    static let defaultGreeting = "Hello Farhad"

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

    static func pageScript(dark: Bool, popOut: Bool, greeting: String, aiNote: String, spellLanguage: String = defaultSpellLanguage) -> String {
        """
        (function () {
          try { if (!localStorage.getItem('numenor-lang')) localStorage.setItem('numenor-lang', 'en-US'); } catch (e) {}
          // Spelling/grammar language from Maziar's Settings; the editor reads it on load and listens for changes.
          window.__maziarSpellLanguage = \(jsString(spellLanguage));
          try { window.dispatchEvent(new CustomEvent('maziar-spell-language', { detail: window.__maziarSpellLanguage })); } catch (e) {}
          var root = document.documentElement;
          if (!document.getElementById('maziar-dark-style')) {
            var style = document.createElement('style');
            style.id = 'maziar-dark-style';
            style.textContent =
              'html.maziar-dark { filter: invert(1) hue-rotate(180deg) brightness(0.92); background: #fff; }' +
              'html.maziar-dark img, html.maziar-dark video, html.maziar-dark canvas, html.maziar-dark object,' +
              'html.maziar-dark iframe { filter: invert(1) hue-rotate(180deg); }';
            (document.head || root).appendChild(style);
          }
          root.classList.toggle('maziar-dark', \(dark ? "true" : "false"));

          // Opening a project is a client-side route change to /editor/<id>. When pop-out is on, turn that
          // into window.open() so the project gets its own Maziar window and the project list stays put.
          // Pages that are themselves popups (window.opener set) navigate normally, and if the window can't
          // be opened (no user gesture, e.g. right after "create project") it falls back to in-page.
          // Start-page title: Numenor builds "Numenor is Here" letter by letter, so rather than fight its
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

          // Numenor's "Workspace Settings" dialog is nothing but AI endpoint / model / key fields. The AI is
          // Maziar's now (Settings \u{2192} AI), so those fields are hidden and a note takes their place.
          window.__maziarAINote = \(jsString(aiNote));
          if (!window.__maziarAIInstalled) {
            window.__maziarAIInstalled = true;
            window.__maziarHideAIFields = function () {
              document.querySelectorAll('.modal-body').forEach(function (body) {
                var fields = Array.from(body.querySelectorAll('.field')).filter(function (field) {
                  var label = field.querySelector('label');
                  return label && /\\b(LLM|VLM)\\b/i.test(label.textContent);
                });
                if (!fields.length) return;
                fields.forEach(function (field) { field.style.display = 'none'; });
                var note = body.querySelector('[data-maziar-ai]');
                if (!note) {
                  note = document.createElement('div');
                  note.setAttribute('data-maziar-ai', '1');
                  note.className = 'muted';
                  note.style.cssText = 'padding: 12px 4px; line-height: 1.6;';
                  body.insertBefore(note, body.firstChild);
                }
                if (note.textContent !== window.__maziarAINote) note.textContent = window.__maziarAINote;
              });
            };
            new MutationObserver(function () { window.__maziarHideAIFields(); })
              .observe(document.documentElement, { childList: true, subtree: true });
          }
          window.__maziarHideAIFields();

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
    @EnvironmentObject private var aiSettings: AISettings

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

    /// Swaps the page's start-up script for the current settings and applies it to the page already showing.
    private var aiNote: String {
        if let ai = server.aiConfig {
            return "AI for Numenor: \(ai.label). It comes from Maziar \u{2014} pick the model in the \u{22EF} menu above (AI model), and manage keys in Maziar \u{2192} Settings \u{2192} AI."
        }
        return "Numenor's AI has no key yet. Add an API key in Maziar \u{2192} Settings \u{2192} AI, then pick the model in the \u{22EF} menu above (AI model)."
    }

    private var providerChoice: Binding<String> {
        Binding(
            get: { aiSettings.numenorProvider?.rawValue ?? "same" },
            set: { aiSettings.numenorProvider = $0 == "same" ? nil : AIProviderKind(rawValue: $0) }
        )
    }

    private func applyPageSettings() {
        guard let view = webViewHolder.view else { return }
        let script = NumenorTheme.pageScript(dark: isDark, popOut: popOutProjects, greeting: greeting, aiNote: aiNote, spellLanguage: spellLanguage)
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
                    Menu("AI model: \(server.aiConfig?.label ?? "none")") {
                        Picker("AI model", selection: providerChoice) {
                            Text("Same as AI Assistant (\(aiSettings.activeProvider.displayName))").tag("same")
                            ForEach(aiSettings.numenorSelectableProviders) { provider in
                                Text("\(provider.displayName) \u{B7} \(aiSettings.model(for: provider))").tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Text("Keys and models: Settings \u{2192} AI")
                    }
                    Toggle("Open projects in a separate window", isOn: $popOutProjects)
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
                documentStartScript: NumenorTheme.pageScript(dark: isDark, popOut: popOutProjects, greeting: greeting, aiNote: aiNote, spellLanguage: spellLanguage)
            )
        }
        .onChange(of: isDark) { _, _ in applyPageSettings() }
        .onChange(of: popOutProjects) { _, _ in applyPageSettings() }
        .onChange(of: greeting) { _, _ in applyPageSettings() }
        .onChange(of: spellLanguage) { _, _ in applyPageSettings() }
        .onChange(of: aiNote) { _, _ in applyPageSettings() }
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
