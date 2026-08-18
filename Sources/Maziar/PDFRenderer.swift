import Foundation
import WebKit

enum PDFRenderingError: LocalizedError {
    case renderingFailed(String)
    var errorDescription: String? {
        switch self {
        case .renderingFailed(let message): return "Couldn't render the PDF: \(message)"
        }
    }
}

/// Renders HTML to a paginated PDF via `WKWebView.createPDF` (the same mechanism behind Safari's
/// "Export as PDF") — kept alive for the duration of the async render by holding a strong
/// reference to itself until the navigation delegate callback fires. Shared by every export
/// feature that needs an HTML-to-PDF table (Conferences, Journals) so the WebKit glue isn't
/// duplicated per feature.
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var selfRetain: PDFRenderer?

    func render(html: String) async throws -> Data {
        selfRetain = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 900))
            self.webView = webView
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.continuation?.resume(returning: data)
            case .failure(let error):
                self.continuation?.resume(throwing: PDFRenderingError.renderingFailed(error.localizedDescription))
            }
            self.continuation = nil
            self.webView = nil
            self.selfRetain = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: PDFRenderingError.renderingFailed(error.localizedDescription))
        continuation = nil
        self.webView = nil
        selfRetain = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: PDFRenderingError.renderingFailed(error.localizedDescription))
        continuation = nil
        self.webView = nil
        selfRetain = nil
    }
}
