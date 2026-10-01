import SwiftUI
import WebKit

/// Renders one notebook cell's assembled HTML — needed because a cell can contain arbitrary
/// styled HTML (the built-in title/box templates use inline CSS: border-radius, box-shadow,
/// custom colors), which SwiftUI's own Markdown rendering (`AttributedString(markdown:)`, used for
/// plain notes) can't render. Auto-sizes to its actual rendered content height — like a real
/// JupyterLab cell, not a fixed-height box with wasted space below short content — via a
/// `ResizeObserver` injected into the page (`NotebookCellHTMLRenderer.fullDocument`) that posts
/// the live height back through a `WKScriptMessageHandler`; re-fires on image load too, since the
/// formula/box-template images decode slightly after the page's own `load` event.
struct NotebookCellWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "heightChanged")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var contentHeight: CGFloat

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = message.body as? Double, height > 0 else { return }
            contentHeight = CGFloat(height)
        }
    }
}
