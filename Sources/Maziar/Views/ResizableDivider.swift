import SwiftUI
import AppKit

/// A draggable vertical bar between two panes — plain SwiftUI (`DragGesture` + a caller-supplied
/// width binding, typically `@AppStorage`-backed so it persists), not `HSplitView`: SwiftUI's
/// `HSplitView` doesn't expose its divider position to app state at all, so there'd be no way to
/// persist it across launches. This gives up nothing visually (a thin draggable line, resize
/// cursor on hover) while being fully under our control. Shared by the Reader window's PDF/tools
/// split and the Library page's optional Scholar-search side panel.
struct ResizableDivider: View {
    @Binding var width: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// False (default) when the pane being resized sits to the divider's *left* (dragging right
    /// grows it — the Reader window's PDF pane). True when the resized pane sits to the divider's
    /// *right* instead (dragging right should shrink it, since the divider is that pane's left
    /// edge) — the Library page's Scholar panel.
    var invertDrag = false

    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
            Rectangle().fill(Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = dragStartWidth ?? width
                    if dragStartWidth == nil { dragStartWidth = width }
                    let delta = invertDrag ? -value.translation.width : value.translation.width
                    width = min(max(base + delta, minWidth), maxWidth)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}
