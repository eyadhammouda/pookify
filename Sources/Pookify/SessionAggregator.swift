import Foundation
import IslandCore

/// Turns the set of on-disk session files into a single decision about what the island should
/// show. Stateless: it reaps dead sessions, recovers frozen ones, and surfaces the
/// highest-priority live session (a permission request always beats one merely working).
struct IslandDecision {
    var visible: Bool
    var provider: Provider
    var state: AgentState
    var label: String
    var detail: String
    var startedAt: Double
    var liveCount: Int
    var forceExpand: Bool

    static let hidden = IslandDecision(visible: false, provider: .claude, state: .idle,
                                       label: "", detail: "", startedAt: 0,
                                       liveCount: 0, forceExpand: false)
}

enum SessionAggregator {

    /// How long a transient state stays on screen before the island collapses.
    static let doneLinger: TimeInterval = 2.5
    static let errorLinger: TimeInterval = 3.5
    // Display caps: when a session stops updating (interrupt, closed extension tab) its last
    // state must not stay on screen forever, so a quiet session goes *display-idle* after a
    // while — WITHOUT deleting its file, so a tool that finally reports back (a 10-minute build,
    // a long test run) resumes with its label and turn clock intact.
    // A tool that is still running (toolEndsAt == 0) gets a long window; quiet reasoning
    // (thinking / a finished tool) goes idle much sooner; permission may legitimately sit.
    static let runningToolCap: TimeInterval = 900
    static let permissionCap: TimeInterval = 7200
    // A "reasoning" session (thinking, or a tool that already finished) is only alive while there's
    // recent activity — a hook firing OR the turn writing to its transcript. Interrupting a turn
    // (terminal Ctrl+C, an editor pause) fires no hook and stops the transcript, so once BOTH have
    // been quiet this long the turn is dead and the island retracts. Sized above the largest gap
    // between transcript writes measured during genuine reasoning (~8s), with margin, so a real
    // think is never hidden; if an unusually slow turn ever trips it, the next write re-opens the
    // island within a couple seconds. Cancelling a request clears the island in about this long.
    static let reasoningIdleCap: TimeInterval = 10
    // How long past its last update a session keeps the app alive (so it can quit when the VS
    // Code extension host — whose pid outlives closed sessions — is all that remains).
    static let appHold: TimeInterval = 300
    // Hard reap: delete a file this old no matter what (protects against pid reuse and junk
    // buildup from extension sessions that never fire session-end).
    static let reapCap: TimeInterval = 7200

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Modification time of the session's transcript, or 0 if none. The turn writes to its
    /// transcript continuously while alive, so this is a liveness signal that survives the gaps
    /// between hooks; it freezes the instant a turn is interrupted.
    static func transcriptMTime(_ s: SessionSnapshot) -> Double {
        guard !s.transcript.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: s.transcript),
              let m = attrs[.modificationDate] as? Date else { return 0 }
        return m.timeIntervalSince1970
    }

    /// The state a session effectively contributes right now (after the display caps).
    static func effectiveState(_ s: SessionSnapshot, now: Double) -> AgentState {
        // A hook firing (ts) OR the turn writing its transcript both count as "still alive".
        func reasoningAlive() -> Bool {
            now - max(s.ts, transcriptMTime(s)) <= reasoningIdleCap
        }
        switch s.state {
        case .thinking:
            return reasoningAlive() ? .thinking : .idle
        case .tool:
            // A finished tool (toolEndsAt > 0) lingers briefly so fast tools are visible, then the
            // session is back to reasoning — surface that as thinking, not a stale tool label.
            if s.toolEndsAt > 0 && now > s.toolEndsAt {
                return reasoningAlive() ? .thinking : .idle
            }
            // A tool still running writes nothing to the transcript (a long build is silent), so it
            // gets a long, plain window rather than the reasoning-liveness check.
            return (now - s.ts > runningToolCap) ? .idle : .tool
        case .permission:
            return (now - s.ts > permissionCap) ? .idle : .permission
        case .done:
            return (now - s.ts <= doneLinger) ? .done : .idle
        case .error:
            return (now - s.ts <= errorLinger) ? .error : .idle
        case .idle:
            return .idle
        }
    }

    /// True when the session's transcript ends with Claude Code's interruption marker — the user
    /// hit stop/pause. Interrupts fire no hook, so this marker (plus the reasoning-liveness cap
    /// above, for the fast Ctrl+C case where the transcript isn't even written) is how an
    /// interrupted turn is noticed. Cheap: reads only the file's tail, only for busy sessions.
    static func wasInterrupted(_ s: SessionSnapshot) -> Bool {
        guard !s.transcript.isEmpty,
              let fh = FileHandle(forReadingAtPath: s.transcript) else { return false }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return false }
        let window: UInt64 = 16384
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return false }
        let text = String(decoding: data, as: UTF8.self)   // lossy-safe at the cut boundary
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true).last,
              last.contains("Request interrupted by user"),   // cheap reject before JSON parse
              // Precise check: only a real *user* interruption entry counts — not conversation
              // text that merely mentions the phrase (e.g. someone discussing this feature).
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              (obj["type"] as? String) == "user",
              let message = obj["message"] as? [String: Any]
        else { return false }
        let marker = "[Request interrupted by user"
        if let str = message["content"] as? String { return str.hasPrefix(marker) }
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.contains {
                ($0["type"] as? String) == "text" && (($0["text"] as? String) ?? "").hasPrefix(marker)
            }
        }
        return false
    }

    /// Read all files, reap dead ones, and decide what to surface.
    static func evaluate(now: Double = Date().timeIntervalSince1970) -> IslandDecision {
        var live: [SessionSnapshot] = []
        for url in StateStore.listFiles() {
            guard var snap = StateStore.read(url) else { continue }
            // Delete a file only on hard evidence: its process died, or it is ancient. Mere
            // staleness hides the session (display-idle above) but keeps the file, preserving
            // turn-clock continuity for tools that go quiet for a long time.
            let processGone = snap.pid > 0 && !pidAlive(snap.pid)
            if processGone || now - snap.ts > reapCap {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // A busy-looking session whose transcript ends in the interruption marker was paused
            // by the user (no hook fires for that in the VS Code extension): show it as idle so
            // the island retracts promptly. The session file stays — the next prompt revives it.
            let eff = effectiveState(snap, now: now)
            if (eff.isWorking || eff == .permission), wasInterrupted(snap) {
                snap.state = .idle
                snap.startedAt = 0
                snap.toolEndsAt = 0
            }
            live.append(snap)
        }

        // Sessions that are visibly doing something — or only went quiet moments ago — keep the
        // app alive. Long-idle files (e.g. closed extension sessions whose host pid persists)
        // don't, so the app can still quit itself.
        let liveCount = live.filter {
            effectiveState($0, now: now) != .idle || now - $0.ts <= appHold
        }.count
        guard !live.isEmpty else { return .hidden }

        // Pick the session most deserving of attention: highest effective priority, then most recent.
        let lead = live.max { a, b in
            let pa = effectiveState(a, now: now).priority
            let pb = effectiveState(b, now: now).priority
            return pa == pb ? a.ts < b.ts : pa < pb
        }!
        let eff = effectiveState(lead, now: now)

        let visible = eff != .idle   // hide while everything rests; the app stays alive
        // When a tool has lingered out to thinking, show "Thinking…" rather than the stale tool label.
        let label = (lead.state == .tool && eff == .thinking) ? "Thinking…" : lead.label
        // The file subtitle only makes sense while actually in a tool (not once it lingers out to thinking).
        let detail = eff == .tool ? lead.detail : ""
        return IslandDecision(
            visible: visible,
            provider: lead.provider,
            state: eff,
            label: label,
            detail: detail,
            startedAt: lead.startedAt,
            liveCount: liveCount,
            forceExpand: eff == .permission
        )
    }
}
