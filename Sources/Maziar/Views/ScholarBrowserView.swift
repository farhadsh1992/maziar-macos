import SwiftUI
import WebKit
import AppKit

/// Holds the live `WKWebView` instance created by `ScholarBrowserView.makeNSView`, as a reference
/// type rather than `@State` — the Reader window's PDF highlighting bug turned out to be exactly
/// this pattern (`@State` written from inside an `NSViewRepresentable.makeNSView`-invoked closure
/// wasn't reliably visible afterward), so the fix learned there is applied here from the start.
@MainActor
final class WebViewHolder: ObservableObject {
    @Published var view: WKWebView?
}

/// `WKWebView`'s default user agent identifies itself as a generic embedded WebKit client, not
/// real Safari — sites can and do react to that by throwing up a forced sign-in wall or, in
/// Google's sign-in library's case, an outright client-side error ("JSON Parse error: Unexpected
/// EOF" — its own JS choking on an empty/rejected response it gets back once its backend detects
/// the non-standard user agent), even for flows that aren't otherwise blocked outright.
/// Applied to every `WKWebView` this file creates, main view and popups alike — a popup spawned
/// via `createWebViewWith` previously didn't get this at all, defaulting back to the generic
/// identity even though the parent view had already been fixed, exactly the gap that let a
/// "Continue with Google" popup hit this error after the *outer* popup-hosting fix already worked.
let embeddedBrowserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

/// Bridges a `WKWebView` into SwiftUI for the Library page's embedded Google Scholar search panel
/// — a real, live, JS-interactive web page inside the app, which SwiftUI has no equivalent for.
struct ScholarBrowserView: NSViewRepresentable {
    let initialURL: URL
    var onViewCreated: (WKWebView) -> Void
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    /// The currently-loaded page's URL, kept live as navigation happens — lets a host view show a
    /// real, Safari-style address bar that tracks where the embedded browser actually is, rather
    /// than staying blank or stuck on whatever was last typed into a separate search field.
    @Binding var currentURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, currentURL: $currentURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = embeddedBrowserUserAgent
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: initialURL))
        onViewCreated(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate, NSWindowDelegate {
        @Binding var canGoBack: Bool
        @Binding var canGoForward: Bool
        @Binding var isLoading: Bool
        @Binding var currentURL: URL?
        /// Keeps each popup window (and its `WKWebView`) alive for as long as it's open — nothing
        /// else in the view hierarchy holds a strong reference to either, so without this the
        /// window returned from `createWebViewWith` would be deallocated the instant this method
        /// returns, before the popup ever had a chance to actually appear.
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

        /// Retains the KVO observation tokens below for as long as this `Coordinator` lives —
        /// letting them fall out of scope would silently stop the observation.
        private var observations: [NSKeyValueObservation] = []

        init(canGoBack: Binding<Bool>, canGoForward: Binding<Bool>, isLoading: Binding<Bool>, currentURL: Binding<URL?>) {
            _canGoBack = canGoBack
            _canGoForward = canGoForward
            _isLoading = isLoading
            _currentURL = currentURL
        }

        /// `didFinish` alone only fires for full page-load navigations — a modern single-page app
        /// (which most sites added as a custom page are) navigates internally via `history
        /// .pushState()`/`replaceState()` far more often than it does a real page load, and *that*
        /// never triggers `didFinish` at all. `canGoBack`/`canGoForward` were only ever refreshed
        /// there, so on any SPA the buttons went stale the moment the user navigated inside the app
        /// itself — reported from real usage as "back or forward is not work" on a newly-added page.
        /// `WKWebView`'s own `canGoBack`/`canGoForward`/`url` are KVO-observable and *do* update
        /// immediately for every kind of navigation, including `pushState` — observing them directly
        /// is Apple's own recommended way to track a WKWebView's live state, and makes this correct
        /// regardless of how the page navigates internally.
        func observe(_ webView: WKWebView) {
            observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                self?.canGoBack = webView.canGoBack
            })
            observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                self?.canGoForward = webView.canGoForward
            })
            observations.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                self?.currentURL = webView.url
            })
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        // -- downloads --

        /// `WKWebView` doesn't support file downloads at all by default — clicking a download
        /// link/button inside an embedded page (e.g. diagrams.net's own File \u{2192} Export/Download)
        /// silently does nothing unless the app explicitly opts the response into becoming a
        /// `WKDownload` and implements `WKDownloadDelegate` to actually save it. Reported from real
        /// usage for the Diagrams page specifically ("website has option for that, but I can not do
        /// it in Maziar"), but this `Coordinator` is the one shared bridge behind every embedded page
        /// in the app (Scholar, Code, Diagrams, custom pages), so fixing it here fixes downloads
        /// everywhere at once. Checks the real `Content-Disposition: attachment` signal first — the
        /// actual, standard way a server indicates "this response wants to be saved, not displayed"
        /// — since relying on MIME-showability alone (`canShowMIMEType`) would misfire for exports
        /// like PNG/SVG, which WKWebView *can* render inline and would otherwise just navigate to
        /// instead of downloading, even though the server intended them as a download.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let httpResponse = navigationResponse.response as? HTTPURLResponse,
               let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
               contentDisposition.lowercased().contains("attachment") {
                decisionHandler(.download)
                return
            }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        /// Prompts a real save panel for where to put the file — same "ask, don't silently write
        /// somewhere unasked" choice as every other download in this app (`LibraryStore
        /// .downloadAndAddPaper`, the Code mode's "Download ZIP"). Returning `nil` (Cancel) cleanly
        /// cancels the download.
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedFilename
                panel.canCreateDirectories = true
                panel.begin { result in
                    completionHandler(result == .OK ? panel.url : nil)
                }
            }
        }

        // -- file uploads --

        /// `WKWebView` has no built-in host for an `<input type="file">` click either — without a
        /// `WKUIDelegate` implementing this method, the click just does nothing at all (no error,
        /// no fallback UI), which is exactly what was reported for the Diagrams page: clicking
        /// draw.io's own "Open" (open an existing diagram from disk) never showed any picker.
        /// Presents a real `NSOpenPanel` and hands the chosen file(s) back to the page — `nil` means
        /// the user cancelled, which WebKit treats the same as picking nothing.
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { result in
                completionHandler(result == .OK ? panel.urls : nil)
            }
        }

        // -- popup windows --

        /// `WKWebView` has no built-in host for a JavaScript `window.open()` call — without a
        /// `WKUIDelegate` implementing this method, the call just fails, and the *page's own*
        /// script sees that failure and shows exactly the "we couldn't open the sign-in window,
        /// check your popup blocker" message the user hit. This is a different, genuinely fixable
        /// problem from Google's own embedded-WebView sign-in block covered elsewhere in this app
        /// (that one is the *server* refusing the credential exchange outright, no client-side fix
        /// possible) — this one is purely "nothing was hosting the popup," which a real
        /// `WKUIDelegate` fixes completely: creates a genuine second `WKWebView`, using the exact
        /// `configuration` WebKit hands in (required — reusing it, rather than building a new one,
        /// is what makes the popup share the parent page's session/cookies, letting an OAuth-style
        /// popup flow actually complete), hosted in a real, separate `NSWindow`.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let width = windowFeatures.width?.doubleValue ?? 520
            let height = windowFeatures.height?.doubleValue ?? 680
            let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self
            popupWebView.customUserAgent = embeddedBrowserUserAgent

            let window = NSWindow(
                contentRect: popupWebView.frame,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sign In"
            window.contentView = popupWebView
            window.delegate = self
            // `NSWindow`'s default `isReleasedWhenClosed = true` makes AppKit itself release the
            // window as part of closing it — on top of `popupWindows` (below) dropping its own
            // strong reference, that's a double release, which crashed with EXC_BAD_ACCESS deep in
            // AppKit's close-animation teardown (`_NSWindowTransformAnimation dealloc`) — reported
            // from real use as the whole app closing right after finishing a sign-in popup (e.g.
            // ChatGPT's own sign-in flow). `popupWindows` is this window's one and only owner now.
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)

            popupWindows[ObjectIdentifier(popupWebView)] = window
            return popupWebView
        }

        /// Called when the popup's own page calls `window.close()` (the normal way an OAuth popup
        /// finishes and closes itself once sign-in completes). Deferred a tick rather than closing
        /// synchronously — this callback runs on WebKit's own call stack for this exact `webView`,
        /// and tearing down its hosting window (and thus the `webView` itself) while still on that
        /// stack risked the same use-after-free class of crash as the `isReleasedWhenClosed` bug
        /// above. `windowWillClose` below does the actual cleanup either way, whether the popup
        /// closed itself (this path) or the user closed it by hand via the window's own close
        /// button (which reaches `windowWillClose` directly, without ever going through this).
        func webViewDidClose(_ webView: WKWebView) {
            let key = ObjectIdentifier(webView)
            DispatchQueue.main.async { [weak self] in
                self?.popupWindows[key]?.close()
            }
        }

        /// The single place a popup's `NSWindow` reference actually gets released — reached from
        /// both `webViewDidClose` above and the window's own titlebar close button, so an entry
        /// never lingers stale in `popupWindows` no matter how the user or the page closes it.
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            popupWindows = popupWindows.filter { $0.value !== window }
        }
    }
}

/// The Library page's optional left-side panel: a small back/forward/reload/search toolbar above a
/// live embedded Google Scholar, so you can search and browse Scholar without leaving the app —
/// e.g. to check a paper's citation count or find one to download and add via URL, right next to
/// the library it'll land in.
struct ScholarSearchPane: View {
    @State private var query = ""
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @StateObject private var webViewHolder = WebViewHolder()

    private var webView: WKWebView? {
        get { webViewHolder.view }
        nonmutating set { webViewHolder.view = newValue }
    }

    private static let homeURL = URL(string: "https://scholar.google.com")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { webView?.load(URLRequest(url: Self.homeURL)) } label: { Image(systemName: "house") }
                TextField("Search Google Scholar…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            ScholarBrowserView(
                initialURL: Self.homeURL,
                onViewCreated: { view in webView = view },
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL
            )
        }
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://scholar.google.com/scholar?q=\(encoded)") else { return }
        webView?.load(URLRequest(url: url))
    }
}
