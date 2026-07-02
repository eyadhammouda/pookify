import SwiftUI
import IslandCore

/// What the island is currently showing. The app controller pushes updates into this on each
/// poll; the SwiftUI view observes it. Hover is owned by the view; `forceExpand` lets the
/// controller auto-open the island on an important change (e.g. a permission request).
@MainActor
final class IslandModel: ObservableObject {
    @Published var isVisible = false
    @Published var provider: Provider = .claude
    @Published var state: AgentState = .idle
    @Published var label: String = ""
    /// Small context under the label, e.g. the file basename ("App.swift"). Empty when none.
    @Published var detail: String = ""
    @Published var startedAt: Double = 0
    /// Auto-open on an important change (e.g. a permission request).
    @Published var forceExpand = false
    /// The user clicked the island to pin it open (iPhone-style tap to expand / tap to close).
    @Published var userExpanded = false
    /// The pointer is over the island (owned by the view; mirrored here so the controller can
    /// tell whether the pill is currently tall before hiding it).
    @Published var hovering = false
    /// True while the island is being hidden: forces the slim presentation regardless of
    /// hover/pin, so the retract animation can NEVER play while the pill is tall.
    @Published var collapsing = false
    /// True while the island is emerging from the notch: forces the slim presentation so the
    /// reveal can NEVER play tall either — it slides out slim first, then expands downward
    /// (e.g. for a permission auto-open).
    @Published var opening = false
    /// Which Claude working glyph to show: the Clawd crab (default), or the official spark.
    @Published var claudeStyle: ClaudeStyle = .crab

    /// Whether the island is currently in its expanded presentation. `forceExpand` (a permission
    /// request) only triggers a one-shot auto-open in the controller; it isn't ORed in here, so the
    /// user can always collapse the island back down even while awaiting permission.
    var isExpanded: Bool { userExpanded }

    /// The pill is (or may be) showing its tall presentation right now.
    var isTall: Bool { (hovering || userExpanded || forceExpand) && !collapsing && !opening }

    /// Top inset (notch height, or menu-bar height on non-notched displays) so the pill tucks
    /// directly under the cutout. @Published so the pill re-lays-out when the display changes.
    @Published var topInset: CGFloat = 32

    /// Width of the physical notch (the camera housing). Content flanks this gap so the island
    /// reads as the notch itself growing. Small synthetic value on non-notched displays.
    @Published var notchWidth: CGFloat = 190

    /// Whether this display actually has a notch (vs. a simulated floating island).
    @Published var hasNotch: Bool = true

    /// Left-click on the island (toggles expand/collapse).
    var onActivate: (() -> Void)?

    // Context-menu (right-click) wiring, provided by the app controller.
    var onQuit: () -> Void = {}
    var onChooseClaudeStyle: (ClaudeStyle) -> Void = { _ in }

    var showsTimer: Bool { state.isWorking && startedAt > 0 }
}
