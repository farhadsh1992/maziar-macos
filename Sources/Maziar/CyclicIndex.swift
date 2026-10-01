/// Wraps `current + delta` into the range `[0, count)` — used for keyboard/scroll navigation
/// through a fixed-size list (the Reader window's highlight-color suggestion popup moving between
/// colors) so stepping past either end cycles around instead of stopping or crashing on an empty
/// list. No SwiftUI/AppKit dependency, so it's headlessly testable on its own.
func cyclicIndex(_ current: Int, movedBy delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let result = (current + delta) % count
    return result < 0 ? result + count : result
}
