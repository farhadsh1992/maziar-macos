import AppKit

/// Exposes the code editor's NSTextView undo manager so toolbar Undo/Redo buttons work
/// regardless of which pane currently has keyboard focus — covers typed edits plus any
/// programmatic replacement that goes through the proper shouldChangeText/didChangeText path
/// (AI-applied fixes, Dynamic PDF edits), since those register with the same undo manager.
@MainActor
final class EditorUndoController: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []

    func attach(_ view: NSTextView) {
        guard textView !== view else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        textView = view

        guard let undoManager = view.undoManager else { return }
        let names: [Notification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            observers.append(observer)
        }
        refresh()
    }

    func undo() {
        textView?.undoManager?.undo()
        refresh()
    }

    func redo() {
        textView?.undoManager?.redo()
        refresh()
    }

    private func refresh() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }
}
