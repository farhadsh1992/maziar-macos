import SwiftUI

/// The dynamic strip under the group bar — auto-rotates every few seconds through Venue / First
/// Author / Year / Institution, each showing a continuously auto-scrolling row of chips built
/// from whatever's actually in the library (`libraryDistinctValues`, `LibraryKeywordField.swift`).
/// Tapping a chip filters the paper list to just that value (wired up by `LibraryView`); tapping
/// the category label on the left jumps to the next category immediately instead of waiting.
struct LibraryKeywordStrip: View {
    let entries: [LibraryEntry]
    let selectedValue: String?
    var onSelect: (LibraryKeywordField, String) -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var activeIndex = 0
    private let rotateTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var activeField: LibraryKeywordField { LibraryKeywordField.allCases[activeIndex] }
    private var valueCounts: [(value: String, count: Int)] { libraryDistinctValueCounts(for: activeField, in: entries) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { advance() }
            } label: {
                Label(activeField.label, systemImage: activeField.icon)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 108, alignment: .leading)
            .help("Tap to switch what this strip shows")

            KeywordMarquee(valueCounts: valueCounts, selectedValue: selectedValue) { value in
                onSelect(activeField, value)
            }
            .id(activeField)
            .transition(.opacity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(settings.color(for: .libraryStripBackground))
        .onReceive(rotateTimer) { _ in
            withAnimation(.easeInOut(duration: 0.4)) { advance() }
        }
    }

    private func advance() {
        activeIndex = (activeIndex + 1) % LibraryKeywordField.allCases.count
    }
}

private struct KeywordMarquee: View {
    let valueCounts: [(value: String, count: Int)]
    let selectedValue: String?
    var onTap: (String) -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var rowWidth: CGFloat = 0
    private let speed: CGFloat = 26
    private let rowGap: CGFloat = 28

    var body: some View {
        if valueCounts.isEmpty {
            Text("Nothing here yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 28, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GeometryReader { geo in
                // Only duplicate the row (the trick that makes the loop seamless) when the
                // content is actually wider than the visible strip — with just one or two chips,
                // the row already fits, so duplicating it just showed the same chip twice
                // side by side, which reads as a bug ("2020 (1)" next to another "2020 (1)")
                // rather than a ticker. A single static row when nothing needs to scroll.
                let needsScroll = rowWidth > geo.size.width
                Group {
                    if needsScroll {
                        TimelineView(.animation) { context in
                            let cycle = max(rowWidth, 1)
                            let elapsed = context.date.timeIntervalSinceReferenceDate
                            let progress = (elapsed * Double(speed)).truncatingRemainder(dividingBy: Double(cycle))
                            HStack(spacing: rowGap) {
                                row
                                row
                            }
                            .fixedSize(horizontal: true, vertical: true)
                            .offset(x: -CGFloat(progress))
                        }
                    } else {
                        row
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .clipped()
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            ForEach(valueCounts, id: \.value) { entry in
                chip(entry.value, count: entry.count)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(RowWidthPreferenceKey.self) { width in
            if width > 0 { rowWidth = width + rowGap }
        }
    }

    private func chip(_ value: String, count: Int) -> some View {
        Button { onTap(value) } label: {
            Text("\(value) (\(count))")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selectedValue?.caseInsensitiveCompare(value) == .orderedSame ? Color.white : Color.primary)
                .background(
                    selectedValue?.caseInsensitiveCompare(value) == .orderedSame
                        ? settings.libraryButtonColor() : Color.secondary.opacity(0.12)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
