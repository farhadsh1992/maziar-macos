import SwiftUI
import PDFKit

final class FocusTrackingPDFView: PDFView {
    var onFocusChange: ((Bool) -> Void)?
    /// (pageIndex 1-based, point in the page's native PDF coordinate space)
    var onCommandClick: ((Int, CGPoint) -> Void)?
    /// Tracks which Data is currently loaded so updateNSView can skip reloading the document
    /// on every SwiftUI refresh (e.g. each zoom-animation frame) without re-serializing the
    /// whole PDF via `document.dataRepresentation()` just to compare — that re-serialization
    /// was the actual cause of the PDF flickering/disappearing during zoom.
    var loadedData: Data?

    /// Dynamic PDF editing: while enabled, plain clicks/drags select and move elements instead
    /// of PDFKit's normal text-selection/scroll handling.
    var dynamicModeEnabled = false
    /// (pageIndex 1-based, point in page space, point in view space)
    var onDynamicMouseDown: ((Int, CGPoint, CGPoint) -> Void)?
    var onDynamicMouseDragged: ((CGPoint) -> Void)?
    var onDynamicMouseUp: ((Int, CGPoint) -> Void)?
    private var isDynamicDragging = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        onFocusChange?(true)
        if event.modifierFlags.contains(.command) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = self.page(for: viewPoint, nearest: true), let document {
                let pagePoint = convert(viewPoint, to: page)
                let pageIndex = document.index(for: page) + 1
                onCommandClick?(pageIndex, pagePoint)
            }
            return
        }
        if dynamicModeEnabled {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = self.page(for: viewPoint, nearest: true), let document {
                let pagePoint = convert(viewPoint, to: page)
                let pageIndex = document.index(for: page) + 1
                isDynamicDragging = true
                onDynamicMouseDown?(pageIndex, pagePoint, topLeftPoint(viewPoint))
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if dynamicModeEnabled, isDynamicDragging {
            onDynamicMouseDragged?(topLeftPoint(convert(event.locationInWindow, from: nil)))
            return
        }
        super.mouseDragged(with: event)
    }

    /// AppKit view coordinates are bottom-left-origin, Y-up; SwiftUI overlay positioning
    /// (`.position(x:y:)`) is top-left-origin, Y-down — flip here once so callers can use the
    /// point directly for HUD placement.
    private func topLeftPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    override func mouseUp(with event: NSEvent) {
        if dynamicModeEnabled, isDynamicDragging {
            isDynamicDragging = false
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = self.page(for: viewPoint, nearest: true), let document {
                let pagePoint = convert(viewPoint, to: page)
                let pageIndex = document.index(for: page) + 1
                onDynamicMouseUp?(pageIndex, pagePoint)
            }
            return
        }
        super.mouseUp(with: event)
    }
}

struct PDFPreviewView: NSViewRepresentable {
    @EnvironmentObject var settings: AppSettings
    var data: Data?
    @ObservedObject var searchController: PDFSearchController
    @ObservedObject var zoomController: PDFZoomController
    @ObservedObject var syncTeX: SyncTeXBridge
    var dynamicModeEnabled: Bool = false
    var onFocus: (() -> Void)?
    var onCommandClick: ((Int, CGPoint) -> Void)?
    var onDynamicMouseDown: ((Int, CGPoint, CGPoint) -> Void)?
    var onDynamicMouseDragged: ((CGPoint) -> Void)?
    var onDynamicMouseUp: ((Int, CGPoint) -> Void)?

    func makeNSView(context: Context) -> PDFView {
        let view = FocusTrackingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(settings.color(for: .previewBackground))
        view.onFocusChange = { focused in
            if focused { onFocus?() }
        }
        view.onCommandClick = { page, point in
            onCommandClick?(page, point)
        }
        view.onDynamicMouseDown = { page, pagePoint, viewPoint in
            onDynamicMouseDown?(page, pagePoint, viewPoint)
        }
        view.onDynamicMouseDragged = { viewPoint in
            onDynamicMouseDragged?(viewPoint)
        }
        view.onDynamicMouseUp = { page, pagePoint in
            onDynamicMouseUp?(page, pagePoint)
        }
        if let data, let doc = PDFDocument(data: data) {
            view.document = doc
            view.loadedData = data
        }
        searchController.pdfView = view
        zoomController.attach(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.backgroundColor = NSColor(settings.color(for: .previewBackground))
        searchController.pdfView = nsView
        zoomController.attach(nsView)
        (nsView as? FocusTrackingPDFView)?.dynamicModeEnabled = dynamicModeEnabled
        if let trackingView = nsView as? FocusTrackingPDFView, let data, trackingView.loadedData != data,
           let doc = PDFDocument(data: data) {
            nsView.document = doc
            trackingView.loadedData = data
        }

        if let target = syncTeX.pendingPDFTarget, let document = nsView.document,
           target.page >= 1, target.page <= document.pageCount,
           let page = document.page(at: target.page - 1) {
            nsView.go(to: PDFDestination(page: page, at: target.point))
            let highlightRect = NSRect(x: target.point.x - 4, y: target.point.y - 8, width: 250, height: 16)
            if let highlightSelection = page.selection(for: highlightRect) {
                nsView.highlightedSelections = [highlightSelection]
            }
            DispatchQueue.main.async { syncTeX.pendingPDFTarget = nil }
        }
    }
}
