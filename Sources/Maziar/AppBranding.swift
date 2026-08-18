import SwiftUI
import AppKit

/// Shared logo/branding — the mark shown in page headers, Settings, the About panel, and (as a
/// low-opacity watermark) the Projects page background.
enum AppBranding {
    static let logoImage: NSImage? = Bundle.module.url(forResource: "Logo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    static var logo: Image? {
        guard let logoImage else { return nil }
        return Image(nsImage: logoImage)
    }

    static let aboutText = """
    Maziar organizes and manages your paper submissions end to end: pick the conference or \
    journal, write the paper, submit it, then rewrite through rebuttal rounds until it's ready \
    for the conference.
    """
}

/// Small logo mark for page headers — used at the top of the Projects, Conferences, and Journals
/// pages, and in Settings.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        if let logo = AppBranding.logo {
            logo
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
