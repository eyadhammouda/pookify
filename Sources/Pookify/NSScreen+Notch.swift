import AppKit

/// Notch geometry, derived from the system's safe-area APIs (macOS 12+) rather than hardcoded
/// pixel sizes, so it's correct across the 14"/16" MacBook Pro and the notched MacBook Air.
extension NSScreen {

    /// True when this display has a camera-housing notch.
    var hasNotch: Bool {
        if #available(macOS 12.0, *) {
            return auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil && safeAreaInsets.top > 0
        }
        return false
    }

    /// The size of the physical notch, if any.
    var notchSize: NSSize? {
        guard #available(macOS 12.0, *),
              let left = auxiliaryTopLeftArea?.width,
              let right = auxiliaryTopRightArea?.width,
              safeAreaInsets.top > 0
        else { return nil }
        let width = frame.width - left - right
        return NSSize(width: width, height: safeAreaInsets.top)
    }

    /// The notch's frame in this screen's coordinate space (top-centered).
    var notchFrame: NSRect? {
        guard let size = notchSize else { return nil }
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// Height to treat as the "notch" on a non-notched display. Real-notch proportions (~32pt,
    /// like the 14" MacBook Pro), or the menu bar if it's taller, so the drawn notch reads
    /// exactly like the hardware one.
    var syntheticNotchHeight: CGFloat {
        let menuBar = frame.maxY - visibleFrame.maxY   // includes the menu bar
        return max(32, menuBar)
    }

    /// Width of the synthetic notch drawn on non-notched displays: the 14" MacBook Pro's
    /// physical notch width, so the island looks identical everywhere.
    static let syntheticNotchWidth: CGFloat = 190

    /// Effective top inset where island content should begin (real notch height or menu bar).
    var islandTopInset: CGFloat { notchSize?.height ?? syntheticNotchHeight }

    /// The screen we should render the island on: prefer a notched screen, else the main screen.
    static var islandScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}
