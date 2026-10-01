import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

/// One open browser session within a multi-tab custom page's own tab bar — same idea as
/// `DiagramsView`'s `DiagramTabModel`, generalized to any custom page instead of being hardcoded to
/// diagrams.net.
private struct CustomPageTabModel: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

/// Embedded browser for a user-added custom page (Settings → Custom Pages) — the same
/// back/forward/reload/home toolbar plus embedded `ScholarBrowserView` shape as the built-in
/// `DiagramsView`, just generalized to any name/URL instead of being hardcoded to diagrams.net.
/// Also reused as-is for the Reader window's AI Chat mode when set to ChatGPT/Claude (see
/// `matchAppearance`/`showOpenInSafari` below) rather than duplicating this toolbar/browser shape
/// for that one-off case.
///
/// When `page.allowMultipleTabs` is on, shows its own tab bar and lets several independent sessions
/// of the same page stay open at once — like a real browser — each tab's content kept permanently
/// mounted once opened (hidden via opacity/hit-testing when not the active tab, not torn down and
/// recreated), the same pattern `DiagramsView`'s own tabs already use and for the same reason:
/// destroying and recreating a tab on every switch would force it to reload from scratch each time.
struct CustomWebPageView: View {
    let page: CustomWebPage
    var matchAppearance: ColorScheme? = nil
    var showOpenInSafari: Bool = true
    var showAddressText: Bool = true

    @State private var tabs: [CustomPageTabModel]
    @State private var activeTabID: UUID
    /// Each tab's live `WKWebView`, reported by `CustomWebPageContentView.onWebViewReady` — lets
    /// `CVAutofillPanel` reach whichever tab is currently active regardless of single- or
    /// multi-tab mode, without owning any browser state itself.
    @State private var webViewsByTabID: [UUID: WKWebView] = [:]

    init(page: CustomWebPage, matchAppearance: ColorScheme? = nil, showOpenInSafari: Bool = true, showAddressText: Bool = true) {
        self.page = page
        self.matchAppearance = matchAppearance
        self.showOpenInSafari = showOpenInSafari
        self.showAddressText = showAddressText
        let firstTab = CustomPageTabModel(title: page.name)
        _tabs = State(initialValue: [firstTab])
        _activeTabID = State(initialValue: firstTab.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            if page.allowMultipleTabs {
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    tabsContent
                }
            } else {
                tabsContent
            }
            if page.showCVAutofillTool {
                Divider()
                CVAutofillPanel(activeWebView: webViewsByTabID[activeTabID])
            }
        }
    }

    private var tabsContent: some View {
        ZStack {
            ForEach(tabs) { tab in
                CustomWebPageContentView(
                    page: page, matchAppearance: matchAppearance, showOpenInSafari: showOpenInSafari, showAddressText: showAddressText,
                    onWebViewReady: { view in webViewsByTabID[tab.id] = view }
                )
                .opacity(tab.id == activeTabID ? 1 : 0)
                .allowsHitTesting(tab.id == activeTabID)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.caption)
                        .lineLimit(1)
                    if tabs.count > 1 {
                        Button {
                            closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    tab.id == activeTabID ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { activeTabID = tab.id }
            }
            Button {
                addTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New \(page.name) tab")
            Spacer()
        }
        .padding(8)
    }

    private func addTab() {
        let newTab = CustomPageTabModel(title: "\(page.name) \(tabs.count + 1)")
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    private func closeTab(_ tab: CustomPageTabModel) {
        guard tabs.count > 1 else { return }
        let wasActive = tab.id == activeTabID
        tabs.removeAll { $0.id == tab.id }
        if wasActive {
            activeTabID = tabs.last?.id ?? activeTabID
        }
    }
}

/// One tab's actual content — everything `CustomWebPageView` used to be before multi-tab support
/// was added. Carries a Light/Dark toggle, one per page (keyed on `page.id`, so different pages —
/// and every tab of the same page — share one preference) — unlike diagrams.net, an arbitrary
/// custom page has no page-side `?dark=` parameter to hook into, so this works by forcing the
/// embedded `WKWebView`'s own AppKit `appearance`, which WebKit reads to decide what
/// `prefers-color-scheme` reports to the page's CSS — the same mechanism Safari itself uses for its
/// per-window "always use dark/light" override. Only affects sites that implement dark mode via
/// `prefers-color-scheme` (the vast majority of modern sites that support it at all); a site with no
/// such CSS simply won't visibly change.
private struct CustomWebPageContentView: View {
    let page: CustomWebPage
    /// When set, forces the embedded page's appearance to follow this rather than the page's own
    /// stored per-page toggle, and hides that toggle entirely — used for the Reader's AI Chat mode,
    /// so ChatGPT/Claude visually matches whatever the Reader window itself is currently showing
    /// (light/dark, live) instead of needing a separate manual choice. `nil` (the default) keeps the
    /// normal independent per-page toggle, used by ordinary custom pages.
    var matchAppearance: ColorScheme? = nil
    /// Hides the "Open in Safari" toolbar button — the Reader's AI Chat mode doesn't want it, since
    /// the whole point of embedding it there is staying inside the paper-reading workflow.
    var showOpenInSafari: Bool = true
    /// Hides the plain-text URL label in the toolbar — the Reader's AI Chat mode has no use for it
    /// (there's nothing to navigate to but the one fixed site) and it just ate toolbar space there.
    var showAddressText: Bool = true
    /// Reports this tab's live `WKWebView` up to the parent `CustomWebPageView` as soon as it's
    /// created — lets a sibling `CVAutofillPanel` reach whichever tab is currently active to inject
    /// its scan/fill scripts into, without this view needing to know that panel exists at all.
    var onWebViewReady: ((WKWebView) -> Void)? = nil

    @AppStorage private var storedIsDarkMode: Bool
    /// The page's zoom level, persisted per page — `WKWebView.pageZoom` (a real, native zoom of the
    /// whole page layout, the same one Safari's Cmd+/Cmd- drives, not just a text-size bump), so a
    /// densely-laid-out site like ChatGPT can be shrunk to fit a narrow companion pane, or enlarged
    /// for readability, independent of every other page.
    @AppStorage private var zoomLevel: Double
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @StateObject private var webViewHolder = WebViewHolder()

    private static let zoomRange = 0.5...2.0
    private static let zoomStep = 0.1

    init(page: CustomWebPage, matchAppearance: ColorScheme? = nil, showOpenInSafari: Bool = true, showAddressText: Bool = true, onWebViewReady: ((WKWebView) -> Void)? = nil) {
        self.page = page
        self.matchAppearance = matchAppearance
        self.showOpenInSafari = showOpenInSafari
        self.showAddressText = showAddressText
        self.onWebViewReady = onWebViewReady
        _storedIsDarkMode = AppStorage(wrappedValue: false, "maziar.customPageDarkMode.\(page.id.uuidString)")
        _zoomLevel = AppStorage(wrappedValue: 1.0, "maziar.customPageZoom.\(page.id.uuidString)")
    }

    private var isDarkMode: Bool {
        if let matchAppearance { return matchAppearance == .dark }
        return storedIsDarkMode
    }

    private var webView: WKWebView? {
        get { webViewHolder.view }
        nonmutating set { webViewHolder.view = newValue }
    }

    private var homeURL: URL {
        URL(string: page.urlString) ?? URL(string: "about:blank")!
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { webView?.load(URLRequest(url: homeURL)) } label: { Image(systemName: "house") }
                if showAddressText {
                    Text(page.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                if matchAppearance == nil {
                    Picker("", selection: $storedIsDarkMode) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: storedIsDarkMode) { _, newValue in
                        applyAppearance(newValue)
                        webView?.reload()
                    }
                }

                HStack(spacing: 4) {
                    Button { adjustZoom(by: -Self.zoomStep) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(zoomLevel <= Self.zoomRange.lowerBound)
                    Text("\(Int((zoomLevel * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38)
                    Button { adjustZoom(by: Self.zoomStep) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(zoomLevel >= Self.zoomRange.upperBound)
                }

                if isLoading {
                    ProgressView().controlSize(.small)
                }
                if showOpenInSafari {
                    Button {
                        NSWorkspace.shared.open(homeURL)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            ScholarBrowserView(
                initialURL: homeURL,
                onViewCreated: { view in
                    webView = view
                    applyAppearance(isDarkMode)
                    view.pageZoom = zoomLevel
                    onWebViewReady?(view)
                },
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL
            )
        }
        .onChange(of: matchAppearance) { _, newValue in
            guard newValue != nil else { return }
            applyAppearance(isDarkMode)
            webView?.reload()
        }
    }

    private func applyAppearance(_ dark: Bool) {
        webView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    private func adjustZoom(by delta: Double) {
        let newZoom = min(max(zoomLevel + delta, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        zoomLevel = newZoom
        webView?.pageZoom = newZoom
    }
}

/// A persistent right-side panel (`page.showCVAutofillTool`) — a native Maziar rebuild of "Farhad's
/// CV AutoFill" browser extension's own popup (logo, status line, and every one of its action
/// buttons), backed by a locally-stored, AI-structured CV (its own separate "Setting" window, opened
/// from the button here — see `CVAutofillSettingsWindow`). Autofill and the two document-generation
/// buttons work off the active tab's actual page content, scraped through `activeWebView
/// .evaluateJavaScript`:
/// - **Autofill this page**: `scanScript` walks the page's visible `input`/`textarea`/`select`
///   elements, tags each with a `data-maziar-autofill-id` attribute so it can be targeted precisely
///   afterward, and returns their labels as JSON; those labels + the stored CV JSON go to
///   `CVAutofillService.proposeAutofillValues`, and the resulting `{fieldId: value}` mapping is
///   written back in via `fillFunctionBody` — using each element's *native* property setter (not a
///   plain `el.value = ...`) before dispatching `input`/`change` events, since a plain assignment
///   alone is silently ignored by React-controlled inputs (LinkedIn's own form fields included) that
///   only react to real DOM events, not property writes. Never touches anything but visible, enabled
///   text-like fields — no checkboxes/radios/file inputs — and never submits the form itself.
/// - **Generate cover letter / Generate tailored CV**: `pageContextScript` grabs the page's title,
///   URL, and visible text once, reused for both — AI drafts the document, shown in a small editor
///   sheet with Copy and a "Download Word" that builds a real `.docx` via `DOCXBuilder` (plain
///   paragraphs only, not the original extension's full rich-text A4 pagination editor).
/// - **Add to Calendar**: same page-context scrape, AI extracts a date/title/location if the page
///   states one, written to a generated `.ics` file and handed to `NSWorkspace.shared.open` — which
///   routes straight to Calendar.app's own "Add Event" sheet, needing no calendar-access permission
///   at all (unlike talking to EventKit directly).
/// - **Save this job**: same scrape, AI extracts a job title/company, saved to `CVAutofillStore
///   .savedJobs` (viewable/removable in the Setting window).
/// - **Ask ChatGPT/Claude**: opens the site picked in Setting → Ask AI in a small window, same shape
///   as Settings → Accounts' sign-in windows.
/// - **Quick Access**: small icon buttons (managed in Setting → Quick Access) that copy a saved
///   snippet of text/link to the clipboard, or open a local file via `NSWorkspace`.
/// Every AI-backed action above uses its own prompt from `CVAutofillService.PromptKey`, editable in
/// Setting → Prompts. Not yet built from the original extension: a per-field right-click "Fill this
/// field" context-menu item.
private struct CVAutofillPanel: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @EnvironmentObject var aiSettings: AISettings
    @Environment(\.openWindow) private var openWindow
    let activeWebView: WKWebView?

    @State private var isRunning = false
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var generatedDocument: GeneratedDocument?
    @State private var showingAddInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let logo = CVAutofillBranding.logo {
                        logo.resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
                    }
                    Text("CV AutoFill").font(.headline)
                    Spacer()
                    Button {
                        openWindow(id: "cv-autofill-settings")
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Setting")
                }

                VStack(alignment: .leading, spacing: 2) {
                    statusLabel(isLoaded: cvAutofillStore.isLoaded, loadedText: cvAutofillStore.cvFileName ?? "CV loaded", missingText: "No CV set")
                    statusLabel(isLoaded: cvAutofillStore.hasCoverLetter, loadedText: "Cover letter saved", missingText: "No cover letter")
                }

                actionButton("Autofill this page", isProminent: true, disabled: isRunning || !cvAutofillStore.isLoaded || activeWebView == nil, action: runAutofill)
                Text("Only fills fields — never clicks Submit. Always review before sending.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                actionButton("Generate cover letter for this page", disabled: isRunning || !cvAutofillStore.isLoaded || activeWebView == nil, action: runGenerateCoverLetter)
                actionButton("Generate tailored CV (Word)", disabled: isRunning || !cvAutofillStore.isLoaded || activeWebView == nil, action: runGenerateTailoredCV)
                Text("Re-emphasizes your real CV content for this job — downloads as a .docx.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 8) {
                    actionButton("Add info", disabled: false) { showingAddInfo = true }
                    actionButton("Add to Calendar", disabled: isRunning || activeWebView == nil, action: runAddToCalendar)
                }

                actionButton(cvAutofillStore.askAITarget.buttonLabel, disabled: false) {
                    openWindow(id: "cv-autofill-ask-ai")
                }
                Text("Opens \(cvAutofillStore.askAITarget.buttonLabel.replacingOccurrences(of: "Ask ", with: "")) in a small window (Setting → Ask AI to change this).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                actionButton("Save this job", isProminent: true, tint: .green, disabled: isRunning || activeWebView == nil, action: runSaveJob)

                if !cvAutofillStore.quickAccessItems.isEmpty {
                    Divider()
                    Text("Quick Access").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                        ForEach(cvAutofillStore.quickAccessItems) { item in
                            Button {
                                runQuickAccess(item)
                            } label: {
                                Text(item.icon)
                                    .font(.title3)
                                    .frame(width: 34, height: 34)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(item.label.isEmpty ? item.type.title : item.label)
                        }
                    }
                }

                if let resultText {
                    Divider()
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(resultIsError ? .red : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .frame(width: 260)
        .sheet(item: $generatedDocument) { document in
            GeneratedDocumentSheet(document: document)
        }
        .sheet(isPresented: $showingAddInfo) {
            AddInfoSheet()
                .environmentObject(cvAutofillStore)
        }
    }

    @ViewBuilder
    private func statusLabel(isLoaded: Bool, loadedText: String, missingText: String) -> some View {
        if isLoaded {
            Label(loadedText, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(missingText, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, isProminent: Bool = false, tint: Color? = nil, disabled: Bool, action: @escaping () -> Void) -> some View {
        let label = HStack {
            if isRunning { ProgressView().controlSize(.small) }
            Text(title)
        }
        .frame(maxWidth: .infinity)

        if isProminent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(disabled)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .tint(tint)
                .disabled(disabled)
        }
    }

    private func runAutofill() {
        guard let webView = activeWebView else { return }
        guard let cvJSON = cvAutofillStore.structuredCVJSON, !cvJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resultIsError = true
            resultText = "No CV set — add one in Settings → CV AutoFill."
            return
        }
        isRunning = true
        resultText = nil
        resultIsError = false
        Task {
            do {
                let scanResult = try await webView.evaluateJavaScript(Self.scanScript)
                guard let fieldsJSONString = scanResult as? String,
                      let fieldsData = fieldsJSONString.data(using: .utf8) else {
                    throw NSError(domain: "Maziar", code: 93, userInfo: [NSLocalizedDescriptionKey: "Couldn't scan this page for form fields."])
                }
                let fields = try JSONDecoder().decode([CVAutofillService.AutofillFieldDescriptor].self, from: fieldsData)
                guard !fields.isEmpty else {
                    resultText = "No fillable fields found on this page."
                    isRunning = false
                    return
                }

                let mapping = try await CVAutofillService.proposeAutofillValues(
                    fields: fields, cvJSON: cvJSON, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .fieldMap)
                )
                guard !mapping.isEmpty else {
                    resultText = "Couldn't confidently match any fields on this page."
                    isRunning = false
                    return
                }

                let mappingData = try JSONEncoder().encode(mapping)
                let base64 = mappingData.base64EncodedString()
                let fillScript = "(\(Self.fillFunctionBody))(JSON.parse(atob(\"\(base64)\")))"
                let filledResult = try await webView.evaluateJavaScript(fillScript)
                let filledCount = (filledResult as? Int) ?? mapping.count
                resultText = "Filled \(filledCount) field\(filledCount == 1 ? "" : "s"). Review before submitting."
                resultIsError = false
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runGenerateCoverLetter() {
        guard let webView = activeWebView else { return }
        guard let cvJSON = cvAutofillStore.structuredCVJSON, !cvJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resultIsError = true
            resultText = "No CV set — add one in Setting."
            return
        }
        isRunning = true
        resultText = nil
        resultIsError = false
        Task {
            do {
                let context = try await scrapePageContext(webView)
                let letter = try await CVAutofillService.generateCoverLetter(
                    context: context, cvJSON: cvJSON, referenceLetter: cvAutofillStore.coverLetterText,
                    notes: cvAutofillStore.notes, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .coverLetterWrite)
                )
                generatedDocument = GeneratedDocument(kind: .coverLetter, text: letter)
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runGenerateTailoredCV() {
        guard let webView = activeWebView else { return }
        guard let cvJSON = cvAutofillStore.structuredCVJSON, !cvJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resultIsError = true
            resultText = "No CV set — add one in Setting."
            return
        }
        isRunning = true
        resultText = nil
        resultIsError = false
        Task {
            do {
                let context = try await scrapePageContext(webView)
                let cv = try await CVAutofillService.generateTailoredCV(
                    context: context, cvJSON: cvJSON, notes: cvAutofillStore.notes, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .cvTailor)
                )
                generatedDocument = GeneratedDocument(kind: .tailoredCV, text: cv)
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runAddToCalendar() {
        guard let webView = activeWebView else { return }
        isRunning = true
        resultText = nil
        resultIsError = false
        Task {
            do {
                let context = try await scrapePageContext(webView)
                let info = try await CVAutofillService.extractEventInfo(
                    context: context, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .eventExtract)
                )
                guard let date = info.date, !date.isEmpty else {
                    resultText = "Couldn't find a clear date on this page."
                    isRunning = false
                    return
                }
                guard let icsURL = ICSWriter.writeEventFile(title: info.title ?? context.title, isoDate: date, location: info.location, notes: info.notes) else {
                    resultIsError = true
                    resultText = "Couldn't build a calendar event from that date."
                    isRunning = false
                    return
                }
                NSWorkspace.shared.open(icsURL)
                resultText = "Opened in Calendar — review and add."
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runSaveJob() {
        guard let webView = activeWebView else { return }
        isRunning = true
        resultText = nil
        resultIsError = false
        Task {
            do {
                let context = try await scrapePageContext(webView)
                let info = try await CVAutofillService.extractJobInfo(
                    context: context, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .jobExtract)
                )
                let job = CVAutofillSavedJob(title: info.title ?? context.title, company: info.company ?? "", link: context.url)
                cvAutofillStore.savedJobs.append(job)
                resultText = "Saved \u{201c}\(job.title)\u{201d}."
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runQuickAccess(_ item: CVAutofillQuickAccessItem) {
        switch item.type {
        case .copyText, .copyLink:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.value, forType: .string)
            resultIsError = false
            resultText = "Copied \u{201c}\(item.label.isEmpty ? item.value : item.label)\u{201d}."
        case .openFile:
            let url = URL(fileURLWithPath: item.value)
            if !NSWorkspace.shared.open(url) {
                resultIsError = true
                resultText = "Couldn't open that file."
            }
        }
    }

    private func scrapePageContext(_ webView: WKWebView) async throws -> CVAutofillService.PageContext {
        let result = try await webView.evaluateJavaScript(Self.pageContextScript)
        guard let jsonString = result as? String, let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "Maziar", code: 94, userInfo: [NSLocalizedDescriptionKey: "Couldn't read this page's content."])
        }
        struct RawContext: Decodable {
            let title: String
            let url: String
            let text: String
        }
        let raw = try JSONDecoder().decode(RawContext.self, from: data)
        return CVAutofillService.PageContext(title: raw.title, url: raw.url, text: raw.text)
    }

    private static let pageContextScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        if (text.length > 6000) text = text.slice(0, 6000);
        return JSON.stringify({ title: document.title, url: location.href, text: text });
    })();
    """

    private static let scanScript = """
    (function() {
        var fields = [];
        var els = document.querySelectorAll('input, textarea, select');
        var counter = 0;
        els.forEach(function(el) {
            if (el.disabled || el.readOnly) return;
            var type = (el.getAttribute('type') || '').toLowerCase();
            if (['hidden','submit','button','reset','image','file','checkbox','radio'].indexOf(type) !== -1) return;
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return;
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;

            var label = '';
            if (el.labels && el.labels.length > 0) {
                label = el.labels[0].innerText || el.labels[0].textContent || '';
            }
            if (!label) label = el.getAttribute('aria-label') || '';
            if (!label) label = el.getAttribute('placeholder') || '';
            if (!label) {
                var wrappingLabel = el.closest('label');
                if (wrappingLabel) label = wrappingLabel.innerText || '';
            }
            if (!label) label = el.getAttribute('name') || el.id || '';
            label = label.trim().replace(/\\s+/g, ' ').slice(0, 200);
            if (!label) return;

            var autofillId = 'maziar-autofill-' + (counter++);
            el.setAttribute('data-maziar-autofill-id', autofillId);
            var tag = el.tagName.toLowerCase();
            fields.push({
                id: autofillId,
                label: label,
                type: tag === 'select' ? 'select' : (type || 'text')
            });
        });
        return JSON.stringify(fields);
    })();
    """

    private static let fillFunctionBody = """
    function(mapping) {
        var filledCount = 0;
        Object.keys(mapping).forEach(function(id) {
            var el = document.querySelector('[data-maziar-autofill-id="' + id + '"]');
            if (!el) return;
            var value = mapping[id];
            if (value === null || value === undefined || value === '') return;

            var tag = el.tagName.toLowerCase();
            if (tag === 'select') {
                el.value = value;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                filledCount++;
                return;
            }

            var proto = tag === 'textarea' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
            var nativeSetter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            nativeSetter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            filledCount++;
        });
        return filledCount;
    }
    """
}

private enum GeneratedDocumentKind {
    case coverLetter
    case tailoredCV

    var title: String {
        switch self {
        case .coverLetter: return "Cover Letter"
        case .tailoredCV: return "Tailored CV"
        }
    }
}

private struct GeneratedDocument: Identifiable {
    let id = UUID()
    let kind: GeneratedDocumentKind
    var text: String
}

/// Shown by `CVAutofillPanel`'s "Generate cover letter"/"Generate tailored CV" buttons — an
/// editable draft with Copy and a real "Download Word" (`DOCXBuilder`, plain paragraphs split on
/// blank lines — not the original extension's full rich-text A4-paginated editor).
private struct GeneratedDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: GeneratedDocument

    @State private var text: String
    @State private var downloadError: String?

    init(document: GeneratedDocument) {
        self.document = document
        _text = State(initialValue: document.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.kind.title).font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13))
                .padding(8)
            if let downloadError {
                CopyableErrorView(message: downloadError).padding(.horizontal)
            }
            Divider()
            HStack {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(action: downloadDocx) {
                    Label("Download Word", systemImage: "arrow.down.doc")
                }
                Spacer()
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    private func downloadDocx() {
        downloadError = nil
        let paragraphs = text.components(separatedBy: "\n\n").map { DOCXBuilder.Paragraph(text: $0) }
        do {
            let data = try DOCXBuilder.build(title: document.kind.title, paragraphs: paragraphs)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(document.kind.title).docx"
            panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

/// Shown by `CVAutofillPanel`'s "Add info" — a small window, same as the original extension's own,
/// for jotting down anything else worth the AI knowing (saved as a `CVAutofillNote`, folded into
/// every autofill/generation prompt alongside the CV).
private struct AddInfoSheet: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Info").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $content)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    cvAutofillStore.addNote(title: title, content: content)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
