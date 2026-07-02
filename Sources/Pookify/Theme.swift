import SwiftUI
import IslandCore

/// Visual constants. Springs are tuned to read as "Apple": a snappy morph on expand with the
/// barest overshoot, a slightly faster collapse so dismissal feels crisp, and a content
/// cross-fade that lags the shape by a hair so content appears to grow out of the pill.
enum Theme {
    // Springs — deliberately slow and fully smooth (no overshoot, no snap). The expand glides the
    // height open; the launch reveal eases the bar out of the notch.
    static let expand   = Animation.spring(response: 0.6, dampingFraction: 1.0)
    // Open/close of the slim bar — unhurried emerge from the notch, and an even calmer retract.
    static let appear    = Animation.spring(response: 1.4, dampingFraction: 0.86)  // open (slow, graceful emerge)
    static let disappear = Animation.spring(response: 1.0, dampingFraction: 1.0)   // retract into notch, smooth, no bounce

    // The pill body — pure, flat black so it fuses seamlessly with the physical notch (no shadow,
    // no gradient: any second tone reads as "not the notch").
    //
    // To experiment with shades WITHOUT rebuilding, launch with the ISLAND_PILL env var:
    //   • a grayscale value 0.0–1.0   (e.g. ISLAND_PILL=0.06  → near-black)
    //   • or a hex string             (e.g. ISLAND_PILL=#0A0A0F)
    // To change the permanent default, edit the `.black` fallback below.
    static let pill: Color = {
        let env = ProcessInfo.processInfo.environment["ISLAND_PILL"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if env.hasPrefix("#"), let c = Color(hexString: env) { return c }
        if let w = Double(env), (0...1).contains(w) { return Color(.sRGB, white: w, opacity: 1) }
        return .black
    }()

    static let amber = Color(.sRGB, red: 0.96, green: 0.74, blue: 0.18, opacity: 1)

    // Pill geometry shared by the view and the window's interactive-zone math.
    static let wing: CGFloat = 56        // each side wing (glyph / timer) of the closed bar
    static let dropHeight: CGFloat = 54  // how much taller the expanded drop-down adds

    static func accent(_ provider: Provider) -> Color {
        let c = provider.accentRGB
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB"). Returns nil if malformed.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255,
                     opacity: 1)
    }
}

/// "0:43" / "1:05" / "12:30" — a compact, single-line media-style clock (with monospaced digits
/// it never reflows or wraps).
func elapsedString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
