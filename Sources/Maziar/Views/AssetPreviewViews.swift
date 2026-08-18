import SwiftUI
import PDFKit

/// Read-only preview for an image asset in the project (not the compiled PDF output).
struct AssetImageView: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Couldn't load image").foregroundStyle(.secondary)
            }
        }
    }
}

/// Read-only preview for a PDF asset in the project (e.g. a figure), distinct from the
/// compiled-output PDFPreviewView (no search/zoom/dynamic-edit machinery needed here).
struct AssetPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
