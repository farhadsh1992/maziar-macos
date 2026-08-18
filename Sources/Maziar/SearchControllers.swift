import AppKit
import PDFKit

@MainActor
final class EditorSearchController: ObservableObject {
    @Published var query: String = "" {
        didSet { search() }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex = 0

    weak var textView: NSTextView?
    private var ranges: [NSRange] = []

    func search() {
        guard let textView, !query.isEmpty else {
            ranges = []
            matchCount = 0
            currentIndex = 0
            return
        }
        let haystack = textView.string as NSString
        var found: [NSRange] = []
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let r = haystack.range(of: query, options: .caseInsensitive, range: searchRange)
            if r.location == NSNotFound { break }
            found.append(r)
            let nextStart = r.location + r.length
            searchRange = NSRange(location: nextStart, length: haystack.length - nextStart)
        }
        ranges = found
        matchCount = found.count
        currentIndex = found.isEmpty ? 0 : 1
        highlightCurrent()
    }

    func next() {
        guard !ranges.isEmpty else { return }
        currentIndex = currentIndex % ranges.count + 1
        highlightCurrent()
    }

    func previous() {
        guard !ranges.isEmpty else { return }
        currentIndex = currentIndex == 1 ? ranges.count : currentIndex - 1
        highlightCurrent()
    }

    func clear() {
        query = ""
        ranges = []
        matchCount = 0
        currentIndex = 0
    }

    private func highlightCurrent() {
        guard let textView, currentIndex > 0, currentIndex <= ranges.count else { return }
        let range = ranges[currentIndex - 1]
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
        textView.showFindIndicator(for: range)
    }
}

@MainActor
final class PDFSearchController: ObservableObject {
    @Published var query: String = "" {
        didSet { search() }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex = 0

    weak var pdfView: PDFView?
    private var selections: [PDFSelection] = []

    func search() {
        guard let pdfView, let document = pdfView.document, !query.isEmpty else {
            selections = []
            matchCount = 0
            currentIndex = 0
            pdfView?.highlightedSelections = nil
            return
        }
        selections = document.findString(query, withOptions: [.caseInsensitive])
        matchCount = selections.count
        currentIndex = selections.isEmpty ? 0 : 1
        highlightCurrent()
    }

    func next() {
        guard !selections.isEmpty else { return }
        currentIndex = currentIndex % selections.count + 1
        highlightCurrent()
    }

    func previous() {
        guard !selections.isEmpty else { return }
        currentIndex = currentIndex == 1 ? selections.count : currentIndex - 1
        highlightCurrent()
    }

    func clear() {
        query = ""
        selections = []
        matchCount = 0
        currentIndex = 0
        pdfView?.highlightedSelections = nil
    }

    private func highlightCurrent() {
        guard let pdfView, currentIndex > 0, currentIndex <= selections.count else { return }
        let selection = selections[currentIndex - 1]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        pdfView.highlightedSelections = [selection]
    }
}
