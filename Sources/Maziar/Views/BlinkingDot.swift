import SwiftUI

/// A small pulsing dot — draws attention (a next deadline, a live status) the way a
/// "live"/recording indicator does, without needing a `Timer` (an ever-repeating animation is
/// enough).
struct BlinkingDot: View {
    var color: Color = .red
    var size: CGFloat = 9
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(isDim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }
}
