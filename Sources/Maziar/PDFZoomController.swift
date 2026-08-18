import PDFKit

@MainActor
final class PDFZoomController: ObservableObject {
    @Published private(set) var scalePercent: Int = 100
    weak var pdfView: PDFView?
    private var observer: NSObjectProtocol?
    private var animationWorkItem: DispatchWorkItem?

    var minScalePercent: Int { Int(((pdfView?.minScaleFactor ?? 0.25) * 100).rounded()) }
    var maxScalePercent: Int { Int(((pdfView?.maxScaleFactor ?? 4.0) * 100).rounded()) }

    func attach(_ view: PDFView) {
        guard pdfView !== view else { return }
        pdfView = view
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func zoomIn() {
        guard let pdfView else { return }
        animate(to: pdfView.scaleFactor * 1.15)
    }

    func zoomOut() {
        guard let pdfView else { return }
        animate(to: pdfView.scaleFactor / 1.15)
    }

    func resetZoom() {
        animate(to: 1.0)
    }

    /// Continuous, immediate scale change — used while dragging a slider, so it tracks the
    /// pointer 1:1 rather than easing (easing would fight/lag behind a live drag).
    func setScale(percent: Double) {
        guard let pdfView else { return }
        animationWorkItem?.cancel()
        pdfView.autoScales = false
        let clamped = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, CGFloat(percent / 100)))
        pdfView.scaleFactor = clamped
        refresh()
    }

    /// Eases the scale factor to `target` over a short duration instead of jumping straight
    /// there, so repeated +/- clicks (or Cmd+/Cmd-) feel smooth rather than jarring.
    private func animate(to target: CGFloat) {
        guard let pdfView else { return }
        animationWorkItem?.cancel()
        pdfView.autoScales = false

        let start = pdfView.scaleFactor
        let clampedTarget = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, target))
        let steps = 6
        let totalDuration = 0.1

        func step(_ i: Int) {
            guard let pdfView = self.pdfView else { return }
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 2) // ease-out
            pdfView.scaleFactor = start + (clampedTarget - start) * CGFloat(eased)
            self.refresh()
            guard i < steps else { return }
            let work = DispatchWorkItem { step(i + 1) }
            self.animationWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration / Double(steps), execute: work)
        }
        step(1)
    }

    private func refresh() {
        guard let pdfView else { return }
        scalePercent = Int((pdfView.scaleFactor * 100).rounded())
    }
}
