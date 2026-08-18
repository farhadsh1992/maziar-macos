import Foundation
import CoreGraphics

/// What a drag-in-progress will do on drop.
enum DynamicDragKind {
    /// Nudge an absolutely-positioned (textblock*) element by the drag delta.
    case freePosition(lineIndex: Int)
    /// Relocate a wrapfigure block near the drop point and flip side based on drop X — stays a
    /// real wrapfigure throughout, so text keeps reflowing around it and reserving its space
    /// (unlike free-position dragging, which is absolute overlay and reserves no space).
    case wrapReposition(beginLine: Int, endLine: Int)
}

/// State for Dynamic PDF editing: click an image/table/figure in the PDF preview to select it,
/// then resize it, nudge its placement, wrap text around it, or (once converted) drag it to an
/// absolute position — each action rewrites the LaTeX source and triggers a recompile.
@MainActor
final class DynamicEditController: ObservableObject {
    @Published var isEnabled = false
    @Published var activeElement: LaTeXElement?
    /// HUD anchor, in the PDFView's own view coordinates (top-left origin, AppKit view space).
    @Published var hudViewPoint: CGPoint?
    @Published var isDragging = false
    /// Live position shown while dragging, before the drag commits.
    @Published var dragPreviewViewPoint: CGPoint?
    @Published var isActiveElementFree = false
    /// (line index of the enclosing \begin{wrapfigure}, current side) if the active element is
    /// already set to wrap text around it.
    @Published var activeWrapfigure: (line: Int, side: String)?

    private var lastClickPagePoint: CGPoint?
    private var lastClickPageHeight: CGFloat?
    private var dragKind: DynamicDragKind?
    private var dragStartPagePoint: CGPoint?

    func selectForHUD(
        _ element: LaTeXElement, viewPoint: CGPoint, pagePoint: CGPoint, pageHeight: CGFloat,
        isFree: Bool, wrapfigure: (line: Int, side: String)? = nil
    ) {
        activeElement = element
        hudViewPoint = viewPoint
        lastClickPagePoint = pagePoint
        lastClickPageHeight = pageHeight
        isActiveElementFree = isFree
        activeWrapfigure = wrapfigure
    }

    /// The current element's click point converted to mm from the page's top-left (TeX-native
    /// convention), for seeding a new absolute position on conversion.
    func clickPointInMM() -> (x: Double, y: Double)? {
        guard let point = lastClickPagePoint, let height = lastClickPageHeight else { return nil }
        return (Double(point.x) * 25.4 / 72.0, Double(height - point.y) * 25.4 / 72.0)
    }

    func clear() {
        activeElement = nil
        hudViewPoint = nil
        isDragging = false
        dragPreviewViewPoint = nil
        lastClickPagePoint = nil
        lastClickPageHeight = nil
        dragKind = nil
        dragStartPagePoint = nil
        isActiveElementFree = false
        activeWrapfigure = nil
    }

    func beginDrag(_ kind: DynamicDragKind, pagePoint: CGPoint, viewPoint: CGPoint) {
        isDragging = true
        dragKind = kind
        dragStartPagePoint = pagePoint
        dragPreviewViewPoint = viewPoint
    }

    func updateDrag(viewPoint: CGPoint) {
        guard isDragging else { return }
        dragPreviewViewPoint = viewPoint
    }

    /// Ends a drag, returning what to do about it. Called on every mouse-up in dynamic mode,
    /// including plain clicks that never started a real drag (non-draggable elements) — in that
    /// case this is a no-op that leaves the HUD open, rather than clearing the selection the
    /// mouse-down just made.
    func endDrag(currentPagePoint: CGPoint) -> (kind: DynamicDragKind, deltaPoints: CGPoint)? {
        guard isDragging, let start = dragStartPagePoint, let kind = dragKind else {
            return nil
        }
        isDragging = false
        dragPreviewViewPoint = nil
        let delta = CGPoint(x: currentPagePoint.x - start.x, y: currentPagePoint.y - start.y)
        dragStartPagePoint = nil
        dragKind = nil
        return (kind, delta)
    }
}
