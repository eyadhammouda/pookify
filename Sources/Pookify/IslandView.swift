import SwiftUI
import AppKit
import IslandCore

/// Root of the notch UI. Anchored flush to the top of the screen so it fuses with the physical
/// notch, easing in/out with the reveal transition.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isVisible {
                IslandPill(model: model)
                    .transition(.notchReveal)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Open/close timing is driven per-direction from the controller (withAnimation) so the
        // retract can be slower than the emerge.
    }
}

/// Open/close motion: the slim bar grows out of the notch — its left and right edges sweep
/// outward from the camera — then settles. On close it retracts back into the notch. Anchored at
/// the top-center (the notch), it scales mostly horizontally so it reads like an iPhone Live
/// Activity appearing/disappearing.
private struct NotchReveal: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        // Pure horizontal scale, anchored at the notch — NO opacity fade. Fading a black pill over
        // the bright wallpaper turns it translucent-gray mid-animation (the "weird gray"); scaling
        // solid black into/out of the notch stays pure black the whole way.
        content
            .scaleEffect(x: max(0, progress), y: 1, anchor: .top)
    }
}
/// Close motion: the slim bar retracts into the notch the way it emerged — its left and right
/// edges sweep inward toward the camera. Pure horizontal scale: no vertical motion (nothing
/// "moves up"), no opacity fade, solid black the whole way. Safe because the hide path always
/// de-expands to the slim bar BEFORE this plays, so x-only never squishes a tall pill.
private struct NotchRetract: ViewModifier {
    let progress: Double   // 1 = full size, 0 = collapsed into the notch
    func body(content: Content) -> some View {
        content.scaleEffect(x: max(0, progress), y: 1, anchor: .top)
    }
}
extension AnyTransition {
    /// Per-direction timing attached to the transition itself (reliable, unlike withAnimation on a
    /// shared ObservableObject): a lively horizontal emerge, and a smooth scale-into-the-notch retract.
    static var notchReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: NotchReveal(progress: 0), identity: NotchReveal(progress: 1))
                .animation(Theme.appear),
            removal: .modifier(active: NotchRetract(progress: 0), identity: NotchRetract(progress: 1))
                .animation(Theme.disappear)
        )
    }
}

/// The notch-fused black island.
///
/// - **Closed (slim):** balanced, symmetric wings — the agent glyph on the left of the camera and
///   the live timer on the right, the same size and distance so it reads perfectly centered on the
///   notch. No words here.
/// - **Expanded:** it grows **taller** (downward), never wider, so it never covers the menu bar.
///   The status wording ("Editing", "Awaiting permission", …) and a detail line drop in *below*
///   the notch. Pure flat black, no shadow — one object with the hardware.
struct IslandPill: View {
    @ObservedObject var model: IslandModel
    @State private var hoverWork: DispatchWorkItem?

    // Symmetric wing metrics — both sides identical so the camera gap is centered.
    private let wing: CGFloat = Theme.wing  // room for a 2-digit:2-digit clock (e.g. 15:48) with even margins
    private let iconSize: CGFloat = 18
    private let dropHeight: CGFloat = Theme.dropHeight
    // The notch shape's concave top corners inset each outer edge by ~topRadius, so content centered
    // in the raw wing lands a few px outside the visible black. Nudge each wing's content toward the
    // notch to optically center it in the area actually available beside the camera.
    private let wingInset: CGFloat = 4

    // `collapsing`/`opening` win over everything: while the island is being hidden OR emerging
    // it must present slim — it never retracts tall and never emerges tall.
    private var expanded: Bool {
        (model.hovering || model.isExpanded) && !model.collapsing && !model.opening
    }
    private var closedH: CGFloat { model.topInset }
    // The camera gap: the physical notch's width, or the synthetic notch's on displays
    // without one — the island renders identically either way.
    private var gap: CGFloat { model.notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing }

    private func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    private var labelW: CGFloat { textWidth(statusTitle, 13.5, .semibold) }

    // Width stays equal to the closed width on a notched Mac (so expanding never widens it). Only on
    // a non-notched display, where the gap is tiny, does it widen enough to fit the dropped-in label.
    private var pillWidth: CGFloat { expanded ? max(closedWidth, labelW + 40) : closedWidth }
    private var pillHeight: CGFloat { expanded ? closedH + dropHeight : closedH }

    var body: some View {
        let topR: CGFloat = 7
        let bottomR: CGFloat = expanded ? 20 : max(10, closedH * 0.40)
        let shape = NotchShape(topRadius: topR, bottomRadius: bottomR)

        ZStack(alignment: .top) {
            shape.fill(Theme.pill)
            VStack(spacing: 0) {
                notchRow
                    .frame(width: closedWidth, height: closedH)
                dropDown
                    .frame(height: dropHeight)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: pillWidth, height: pillHeight, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { isOver in
            hoverWork?.cancel()
            if isOver {
                // small intent delay so a passing pointer doesn't pop it open
                let work = DispatchWorkItem { model.hovering = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                model.hovering = false
            }
        }
        .onTapGesture { model.onActivate?() }
        .contextMenu { menuItems }
        .animation(Theme.expand, value: expanded)
        .animation(Theme.expand, value: model.state)
        .animation(Theme.expand, value: model.showsTimer)
    }

    // MARK: closed row (balanced, centered on the camera)

    private var notchRow: some View {
        HStack(spacing: 0) {
            // Left wing — the agent's mark, ALWAYS here, centered (never moves between states).
            // Animates while working; when the turn is done it rests on its fullest frame (a
            // complete spark next to the checkmark), never frozen mid-morph.
            AgentGlyph(provider: model.provider, claudeStyle: model.claudeStyle,
                       working: model.state.isWorking, size: iconSize)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .offset(x: wingInset)                  // nudge toward the notch to optically center

            Color.clear.frame(width: gap, height: closedH)

            // Right wing — the status, centered to mirror the agent mark: timer while working,
            // a check when done, an amber dot for permission, a warning on error.
            rightStatus
                .frame(width: wing, height: closedH)
                .offset(x: -wingInset)                 // mirror nudge so the bar stays balanced
        }
    }

    @ViewBuilder private var rightStatus: some View {
        if model.showsTimer {
            TimerText(startedAt: model.startedAt)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        } else {
            switch model.state {
            case .permission:
                Circle().fill(Theme.amber).frame(width: 8, height: 8)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize * 0.62, weight: .bold))
                    .foregroundStyle(Theme.accent(model.provider))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize * 0.6, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            default:
                Color.clear
            }
        }
    }

    // MARK: drop-down (the taller part — words live here)

    private var dropDown: some View {
        VStack(spacing: 4) {
            if model.state.isWorking {
                // Live "AI shimmer" sweeping across the current activity word + dots.
                WorkingLabel(word: statusWord)
            } else {
                Text(statusTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Capsule()
                .fill(accentColor)
                .frame(width: 26, height: 2.5)
                .opacity(0.9)
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 5)
    }

    @ViewBuilder private var menuItems: some View {
        Menu("Claude icon") {
            Button((model.claudeStyle == .spark ? "✓ " : "") + "Spark") { chooseStyle(.spark) }
            Button((model.claudeStyle == .crab ? "✓ " : "") + "Clawd (crab)") { chooseStyle(.crab) }
        }
        Divider()
        Button("Quit") { model.onQuit() }
    }

    /// Apply a Claude icon choice and drop the hover state. Opening the context menu can swallow the
    /// pointer-exit event, leaving `hovering` stuck true (the pill stays expanded after the menu
    /// closes); clearing it here collapses the pill cleanly once you move away.
    private func chooseStyle(_ style: ClaudeStyle) {
        hoverWork?.cancel()
        model.hovering = false
        model.onChooseClaudeStyle(style)
    }

    private var accentColor: Color {
        switch model.state {
        case .permission, .error: return Theme.amber
        default:                  return Theme.accent(model.provider)
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .permission: return "Awaiting permission"
        case .done:       return "Done"
        case .error:      return "Error"
        case .idle:       return "Idle"
        default:          return model.label.isEmpty ? "Working…" : model.label
        }
    }

    /// The working label with any trailing dots stripped (WorkingLabel adds its own animated ellipsis).
    private var statusWord: String {
        var w = statusTitle
        while let last = w.last, last == "…" || last == "." || last == " " { w.removeLast() }
        return w
    }
}

/// The active-status word with a soft left-to-right "AI shimmer" (a bright band sweeps across the dim
/// text) plus an animated ellipsis. Driven from absolute time so the motion is smooth and continuous.
struct WorkingLabel: View {
    let word: String

    var body: some View {
        // 30 updates/s is visually indistinguishable for a slow 2.6s shimmer sweep and gentle
        // dots, and far cheaper than the display-refresh-rate (up to 120Hz) default.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(word)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .overlay(alignment: .trailing) {
                    // animated ellipsis just past the word, so the label width never jiggles
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().frame(width: 2.6, height: 2.6).opacity(dotOpacity(t, i))
                        }
                    }
                    .offset(x: 13, y: 1)
                }
                .padding(.trailing, 15)   // reserve room for the dots
                .foregroundStyle(shimmer(t))
        }
    }

    private func dotOpacity(_ t: Double, _ i: Int) -> Double {
        let cycle = (t * 2.2).truncatingRemainder(dividingBy: 3.0)   // 0..3, one dot lights at a time
        return 0.2 + 0.8 * max(0, 1 - abs(cycle - Double(i)))
    }

    /// A dim gradient with a soft bright band whose center sweeps left→right and loops. Gentle:
    /// slow sweep and low contrast so it reads as a subtle shimmer, not a strobe.
    private func shimmer(_ t: Double) -> LinearGradient {
        let period = 2.6
        let p = (t.truncatingRemainder(dividingBy: period)) / period   // 0..1
        let c = p * 1.4 - 0.2                                            // band center: -0.2 … 1.2
        func loc(_ v: Double) -> Double { min(1, max(0, v)) }
        let dim = Color.white.opacity(0.62)
        let bright = Color.white.opacity(0.9)
        return LinearGradient(
            stops: [
                .init(color: dim,    location: 0),
                .init(color: dim,    location: loc(c - 0.3)),
                .init(color: bright, location: loc(c)),
                .init(color: dim,    location: loc(c + 0.3)),
                .init(color: dim,    location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// Live elapsed clock, ticking each second. Never wraps (single line, monospaced).
struct TimerText: View {
    let startedAt: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(Int(context.date.timeIntervalSince1970 - startedAt)))
        }
    }
}
