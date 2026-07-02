import AppKit
import SwiftUI

/// A borderless panel that floats over the notch on every Space, above the menu bar, without
/// stealing focus from the user's terminal. It hosts the SwiftUI island and passes clicks
/// through everywhere except the small interactive zone around the pill.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // Sit just above the menu bar / ordinary status items so the island is always visible.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        // Don't show in the window cycle / screenshots of windows.
        isExcludedFromWindowsMenu = true
    }

    // NEVER take key status: becoming key would steal typing focus from the user's terminal or
    // editor the moment they click the island. Mouse events (tap to pin, right-click menu) are
    // delivered to a non-activating panel without key status, so nothing is lost.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only claims mouse events inside `interactiveRect` (window/bottom-left
/// coordinates). Everywhere else it returns nil so the click falls through to whatever is
/// beneath — the menu bar, the desktop, another app.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    /// Deliver the first click even though the app is never active (the panel never becomes
    /// key), so tapping the island works without a focus-shifting "activation click" first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel + hosting view and keeps the island positioned on the correct screen.
@MainActor
final class NotchWindowController {
    private let model: IslandModel
    private var panel: NotchPanel?
    private var hosting: PassthroughHostingView<IslandRootView>?

    // The interactive zone hugs the pill (small margin for hover comfort). Anything outside it —
    // including most of the menu bar — passes every event straight through to whatever is
    // beneath, so the island never intercepts clicks or focus meant for other UI.

    init(model: IslandModel) {
        self.model = model
        // Register once, up front — independent of whether the first install() finds a screen — so a
        // display connecting later (e.g. app launched before screens settled) still builds the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func install() {
        guard panel == nil, let screen = NSScreen.islandScreen else { return }
        applyScreen(screen)
        let frame = panelFrame(for: screen)

        let root = IslandRootView(model: model)
        let hosting = PassthroughHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.layer?.isOpaque = false

        let panel = NotchPanel(contentRect: frame)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = hosting
        updateInteractiveZone()
    }

    /// Feed the screen's notch geometry to the model so content can flank the camera correctly.
    /// On displays without a physical notch, the island draws a synthetic one with real-notch
    /// proportions, so it looks exactly the same everywhere.
    /// Dev: ISLAND_FORCE_NO_NOTCH=1 exercises the synthetic path on a notched Mac.
    private func applyScreen(_ screen: NSScreen) {
        let forceNoNotch = ProcessInfo.processInfo.environment["ISLAND_FORCE_NO_NOTCH"] == "1"
        if screen.hasNotch && !forceNoNotch {
            model.topInset = screen.islandTopInset
            model.notchWidth = screen.notchSize?.width ?? NSScreen.syntheticNotchWidth
            model.hasNotch = true
        } else {
            model.topInset = screen.syntheticNotchHeight
            model.notchWidth = NSScreen.syntheticNotchWidth
            model.hasNotch = false
        }
    }

    /// Panel covers the top strip of the screen, anchored to the very top so SwiftUI's top edge
    /// aligns with the screen top (and thus the notch).
    private func panelFrame(for screen: NSScreen) -> NSRect {
        let w = screen.frame.width
        let h: CGFloat = 240
        return NSRect(x: screen.frame.minX,
                      y: screen.frame.maxY - h,
                      width: w,
                      height: h)
    }

    private func updateInteractiveZone() {
        guard let hosting else { return }
        let h = hosting.bounds.height
        let w = hosting.bounds.width
        // Match the pill's real footprint: its width plus a small hover margin, and its fully
        // expanded height (notch band + drop-down).
        let zoneWidth = Theme.wing + model.notchWidth + Theme.wing + 32
        let zoneHeight = model.topInset + Theme.dropHeight + 24
        // Top-centered box in bottom-left window coordinates.
        let rect = CGRect(x: (w - zoneWidth) / 2,
                          y: h - zoneHeight,
                          width: zoneWidth,
                          height: zoneHeight)
        hosting.interactiveRect = model.isVisible ? rect : .zero
    }

    /// Call when visibility changes so we don't capture clicks while the island is hidden.
    func refreshInteractivity() { updateInteractiveZone() }

    @objc private func screensChanged() {
        // A screen appeared after a deferred launch (none available at install time) → build now.
        if panel == nil { install(); return }
        guard let panel, let screen = NSScreen.islandScreen else { return }
        applyScreen(screen)
        let frame = panelFrame(for: screen)
        panel.setFrame(frame, display: true)
        hosting?.frame = NSRect(origin: .zero, size: frame.size)
        updateInteractiveZone()
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}
