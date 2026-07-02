import AppKit
import SwiftUI
import IslandCore

/// Ties everything together: polls the session files, drives the island model, shows the menu,
/// and self-quits when nothing is running so there's no idle process to manage.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private lazy var windowController = NotchWindowController(model: model)
    private var pollTimer: Timer?

    private let launchedAt = Date()
    private var notNeededSince: Date?
    private let launchGrace: TimeInterval = 5   // settle time before we may quit
    private let idleQuitDelay: TimeInterval = 4 // "nothing running" must persist this long

    func applicationDidFinishLaunching(_ notification: Notification) {
        Island.ensureDirs()

        // Single instance: if another live Pookify already owns the notch (e.g. the demo harness
        // binary alongside the installed app), bow out instead of drawing a second island.
        if let s = try? String(contentsOf: Island.appPidFile, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
           pid != ProcessInfo.processInfo.processIdentifier,
           kill(pid, 0) == 0,
           let other = NSRunningApplication(processIdentifier: pid),
           other.executableURL?.lastPathComponent == Island.executableName {
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)"
            .write(to: Island.appPidFile, atomically: true, encoding: .utf8)

        // Wire up hooks on first launch / version change, off the main thread.
        // ISLAND_NO_INSTALL=1 skips this (used for development / screenshots so we never touch
        // the user's real ~/.claude config unexpectedly).
        if ProcessInfo.processInfo.environment["ISLAND_NO_INSTALL"] != "1" {
            DispatchQueue.global(qos: .utility).async {
                _ = HookInstaller.ensureInstalledIfNeeded()
            }
        }

        // Restore the saved Claude icon style (env override for dev/screenshots).
        if let raw = ProcessInfo.processInfo.environment["ISLAND_CLAUDE_STYLE"] ?? UserDefaults.standard.string(forKey: "claudeStyle"),
           let style = ClaudeStyle(rawValue: raw) {
            model.claudeStyle = style
        }

        model.onActivate = { [weak self] in self?.toggleExpanded() }
        model.onQuit = { [weak self] in self?.quit() }
        model.onChooseClaudeStyle = { [weak self] style in self?.chooseClaudeStyle(style) }
        windowController.install()

        // Demo/dev: force the expanded presentation so every state can be captured.
        if ProcessInfo.processInfo.environment["ISLAND_FORCE_EXPAND"] == "1" {
            model.userExpanded = true
        }

        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
    }

    // MARK: poll loop

    private var pollInFlight = false

    private func tick() {
        // Skip if the previous poll's disk work hasn't finished, so slow I/O can't pile up.
        guard !pollInFlight else { return }
        pollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Directory listing + JSON decode + reaping happen off the main thread so the UI
            // (and the menu-bar passthrough) never stalls on disk.
            let decision = SessionAggregator.evaluate()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pollInFlight = false
                    self.apply(decision)
                    self.checkLifecycle(liveCount: decision.liveCount)
                }
            }
        }
    }

    /// Push a decision into the model, only touching properties that actually changed so SwiftUI
    /// doesn't re-render 2-3 times a second for nothing.
    private var hidePending = false
    private var hideWork: DispatchWorkItem?
    private var openingWork: DispatchWorkItem?

    private func apply(_ d: IslandDecision) {
        let wasVisible = model.isVisible

        if d.visible {
            hidePending = false
            hideWork?.cancel(); hideWork = nil   // a session reappeared mid-collapse: cancel the hide
            if model.collapsing { model.collapsing = false }
            if !model.isVisible {
                model.isVisible = true
                // Never emerge in the expanded presentation: slide out as the slim bar first,
                // then expand downward once the reveal has settled (mirror of the hide path).
                model.opening = true
                openingWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.model.opening = false
                        self.openingWork = nil
                    }
                }
                openingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: work)
            }
            if model.provider != d.provider { model.provider = d.provider }
            if model.state != d.state { model.state = d.state }
            if model.label != d.label { model.label = d.label }
            if model.detail != d.detail { model.detail = d.detail }
            if model.startedAt != d.startedAt { model.startedAt = d.startedAt }
            // A permission request auto-opens the island ONCE (rising edge) and auto-collapses when it
            // clears (falling edge). In between the user can freely collapse it — forceExpand no longer
            // pins it open.
            let wasForce = model.forceExpand
            if model.forceExpand != d.forceExpand { model.forceExpand = d.forceExpand }
            if d.forceExpand && !wasForce { setExpanded(true) }
            else if !d.forceExpand && wasForce { setExpanded(false) }
        } else if model.isVisible && !hidePending {
            // Hiding: NEVER retract while the pill is tall — whether pinned open, auto-opened for
            // a permission, or just hovered. De-expand to the slim bar first, then retract it.
            if model.isTall {
                hidePending = true
                openingWork?.cancel(); openingWork = nil
                model.opening = false
                if model.forceExpand { model.forceExpand = false }
                model.collapsing = true   // overrides hover/pin so the pill presents slim
                setExpanded(false)
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.model.isVisible = false
                        self.model.collapsing = false
                        self.hidePending = false
                        self.hideWork = nil
                        self.windowController.refreshInteractivity()
                    }
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            } else {
                model.isVisible = false
            }
        }

        if wasVisible != model.isVisible { windowController.refreshInteractivity() }
    }

    // MARK: expand / collapse (iPhone-style click to open, click away to close)

    private var clickMonitor: Any?

    private func toggleExpanded() { setExpanded(!model.userExpanded) }

    private func setExpanded(_ on: Bool) {
        if model.userExpanded != on { model.userExpanded = on }
        if on {
            if clickMonitor == nil {
                // A click anywhere outside our own windows collapses the island.
                clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setExpanded(false) }
                }
            }
        } else if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    /// Quit when nothing has been running for a short, debounced grace period.
    private func checkLifecycle(liveCount: Int) {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if liveCount > 0 { notNeededSince = nil; return }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    private func chooseClaudeStyle(_ style: ClaudeStyle) {
        model.claudeStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "claudeStyle")
    }

    /// Quit gracefully: de-expand to the slim bar, retract into the notch, and only then
    /// terminate — the island must never just vanish (least of all while tall).
    @objc private func quit() {
        guard model.isVisible, !quitting else {
            if !quitting { NSApp.terminate(nil) }
            return
        }
        quitting = true
        pollTimer?.invalidate(); pollTimer = nil   // freeze state; no new decisions mid-goodbye
        hideWork?.cancel(); hideWork = nil
        model.forceExpand = false
        model.collapsing = true                     // slim first…
        setExpanded(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isVisible = false        // …then play the retract…
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }  // …then actually exit.
                }
            }
        }
    }
    private var quitting = false

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        windowController.tearDown()
        // Only clear the pid file if it is ours — a losing second instance must not erase the
        // winner's liveness marker on its way out.
        if let s = try? String(contentsOf: Island.appPidFile, encoding: .utf8),
           Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: Island.appPidFile)
        }
    }
}
