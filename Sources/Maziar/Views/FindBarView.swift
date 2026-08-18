import SwiftUI

struct FindBarView: View {
    @Binding var query: String
    let matchCount: Int
    let currentIndex: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onNext() }
                .frame(minWidth: 120)

            if !query.isEmpty {
                Text(matchCount == 0 ? "No results" : "\(currentIndex)/\(matchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 14)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
        .padding(8)
        .onAppear { focused = true }
    }
}
