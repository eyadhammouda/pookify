import Foundation
import IslandCore

// island-hook — the bridge between Claude Code's hooks and the notch app.
//
// Invoked by Claude Code hooks as:   island-hook claude <kind>
//   kind:     session-start | prompt | pre | post | post-fail | permission | denied |
//             notify | subagent-start | subagent-stop | compact | stop | stop-fail | session-end
//
// The hook's JSON payload arrives on stdin. We map the event to this session's normalized
// state and write it atomically to a per-session file. Hooks must be fast and must never
// fail the agent, so everything here is best-effort and exits 0.

let args = CommandLine.arguments
let providerArg = args.count > 1 ? args[1] : ""
let kind = args.count > 2 ? args[2] : ""
let provider = Provider(rawValue: providerArg) ?? .claude

// Read the hook payload (JSON on stdin). Tolerate empty/garbage input.
let rawInput = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: rawInput) as? [String: Any]) ?? [:]

func str(_ key: String) -> String { (payload[key] as? String) ?? "" }

// The agent process that spawned this hook (stable for the session). kill(pid,0) drives liveness.
let parentPID = getppid()

func now() -> Double { Date().timeIntervalSince1970 }

// How long a finished fast tool's label (and file name) lingers before the island falls back to
// "Thinking…". Long enough to actually read the file name on a quick Read/Edit, without holding a
// stale label so long it feels laggy.
let toolLingerSeconds = 1.9

// Debug tracing: ISLAND_DEBUG=1 in the agent's environment, or — since hooks spawned by the
// VS Code extension don't inherit a terminal's env — the presence of a `debug-on` file next to
// the state directory (`touch "~/Library/Application Support/Pookify/debug-on"`).
let debugOn = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    || FileManager.default.fileExists(atPath: Island.supportDir.appendingPathComponent("debug-on").path)

func debugLog(_ msg: String) {
    guard debugOn else { return }
    Island.ensureDirs()
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: Island.debugLog) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? data.write(to: Island.debugLog)
    }
}

// session_id is resolved just below; log it here so a specific session can be isolated in the
// trace (the VS Code extension interleaves several). Kept short for readable lines.
let dbgSess = str("session_id").isEmpty ? "pid-\(parentPID)" : String(str("session_id").prefix(8))
if debugOn {
    debugLog("[\(dbgSess)] [\(provider.rawValue)/\(kind)] tool=\(str("tool_name")) type=\(str("notification_type")) source=\(str("source")) permMode=\(str("permission_mode")) keys=\(payload.keys.sorted().joined(separator: ","))")
}

// Resolve which session this is. Hook payloads carry session_id; fall back to the agent pid
// so a payload without one still maps to a stable file for the session's lifetime.
let sessionId: String = {
    let s = str("session_id")
    return s.isEmpty ? "pid-\(parentPID)" : s
}()

let cwd = str("cwd")
let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
let model = str("model")

// Previous snapshot (for turn-start continuity and carrying over fields the event lacks).
let prev = StateStore.read(StateStore.fileURL(provider: provider, sessionId: sessionId))

// Claude Code stamps every event of one turn with the same prompt_id. The turn clock
// (`startedAt`) belongs to a turn, so we key it off this: the clock only restarts when a
// genuinely new turn begins. Carry the current turn's id forward on events that omit it.
let eventPromptId = str("prompt_id")
let turnPromptId = eventPromptId.isEmpty ? (prev?.promptId ?? "") : eventPromptId
// True when this event belongs to the SAME turn as the last snapshot — so re-fired activity
// within a turn (e.g. the VS Code extension re-emitting a prompt/tool around a permission
// accept) must NOT reset the clock.
let sameTurn = !turnPromptId.isEmpty && turnPromptId == (prev?.promptId ?? "")

func launchApp() {
    // Bring the (background) app up if it isn't already. Ignore failures (e.g. not yet
    // registered with Launch Services during local development).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", Island.bundleID]
    try? p.run()
    // Dev convenience: if an explicit app path is provided, try that too.
    if let path = ProcessInfo.processInfo.environment["ISLAND_APP_PATH"], !path.isEmpty {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        q.arguments = ["-g", path]
        try? q.run()
    }
}

/// Whether the notch app is currently running, via the pid file it maintains. A missing or
/// stale pid reads as "not running", which just means we spawn a redundant `open` — harmless.
func appIsRunning() -> Bool {
    guard let s = try? String(contentsOf: Island.appPidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return false }
    return kill(pid, 0) == 0
}

// The file a file-tool is acting on, basename only ("App.swift"), for the status subtitle. Empty for
// tools without a file path. Read from the hook's tool_input payload.
func toolDetail() -> String {
    guard let input = payload["tool_input"] as? [String: Any] else { return "" }
    for key in ["file_path", "notebook_path", "path"] {
        if let p = input[key] as? String, !p.isEmpty { return (p as NSString).lastPathComponent }
    }
    return ""
}

func writeState(_ state: AgentState, label: String, tool: String = "", startedAt: Double,
                started: Bool, toolEndsAt: Double = 0, detail: String = "") {
    let snap = SessionSnapshot(
        provider: provider,
        sessionId: sessionId,
        state: state,
        label: label,
        tool: tool,
        project: project.isEmpty ? (prev?.project ?? "") : project,
        cwd: cwd.isEmpty ? (prev?.cwd ?? "") : cwd,
        model: model.isEmpty ? (prev?.model ?? "") : model,
        pid: parentPID,
        startedAt: startedAt,
        ts: now(),
        started: started,
        toolEndsAt: toolEndsAt,
        detail: detail,
        promptId: turnPromptId,
        transcript: str("transcript_path").isEmpty ? (prev?.transcript ?? "") : str("transcript_path")
    )
    StateStore.write(snap)
    debugLog("    wrote state=\(state.rawValue) label=\(label) startedAt=\(String(format: "%.1f", startedAt)) promptId=\(turnPromptId.prefix(8)) (prev.startedAt=\(String(format: "%.1f", prev?.startedAt ?? 0)) prev.state=\(prev?.state.rawValue ?? "nil"))")
}

/// The turn's start time: reuse the previous snapshot's when we're still in the same turn (a
/// running clock), otherwise start it now. This is the single source of truth for the clock.
func turnStart() -> Double {
    if sameTurn, let s = prev?.startedAt, s > 0 { return s }
    return carriedStart > 0 ? carriedStart : now()
}

let carriedStart = prev?.startedAt ?? 0

switch kind {
case "session-start":
    // Auto-compaction restarts the session mid-turn (SessionStart fires again with
    // source:"compact"): keep the turn alive and its clock intact instead of resetting to idle,
    // so the island doesn't blink and the timer doesn't restart in the middle of real work.
    // (A manual /compact between turns was idle before compacting — prev says so — and resets.)
    if str("source") == "compact", let p = prev, p.tool == "compact-auto" {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    } else {
        // Seed an idle marker so the session counts immediately. started:false keeps a
        // merely-opened session quiet until it does real work.
        writeState(.idle, label: "", startedAt: 0, started: false)
    }

case "prompt":
    // A prompt with a NEW prompt_id starts a fresh turn: clock from NOW — even if the previous
    // turn never got a Stop (an interrupted extension turn leaves a stale working snapshot, and
    // carrying its clock forward would show a bogus old timer). Only a prompt re-fired within the
    // SAME turn — which the VS Code extension can do around a permission accept — resumes the
    // running clock.
    writeState(.thinking, label: "Thinking…",
               startedAt: sameTurn && carriedStart > 0 ? carriedStart : now(), started: true)

case "pre":
    let tool = str("tool_name")
    writeState(.tool, label: toolLabel(provider: provider, tool: tool), tool: tool,
               startedAt: turnStart(), started: true,
               detail: toolDetail())

case "post", "post-fail":
    // The tool just finished. Keep its label (and the file name) up for a short linger: fast tools
    // fire pre+post within milliseconds — faster than the app's poll — so without this every
    // read/edit/command would flash by too fast to read. The linger holds the label ~1.9s after the
    // tool finishes, long enough to actually read the file name, then the app falls back to
    // "Thinking…" for the reasoning that follows. So the status is visible and readable during
    // tools AND accurate ("Thinking…") while it reasons.
    let postTool = str("tool_name").isEmpty ? (prev?.tool ?? "") : str("tool_name")
    if postTool.isEmpty {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    } else {
        let d = toolDetail().isEmpty ? (prev?.detail ?? "") : toolDetail()
        writeState(.tool, label: toolLabel(provider: provider, tool: postTool), tool: postTool,
                   startedAt: turnStart(), started: true,
                   toolEndsAt: now() + toolLingerSeconds, detail: d)
    }

case "subagent-start":
    writeState(.tool, label: "Delegating", tool: "Task",
               startedAt: turnStart(), started: true)

case "subagent-stop":
    // Only a session that is actually mid-turn goes back to "Thinking…". Claude Code also runs
    // background auxiliary agents (conversation title, memory) whose SubagentStop lands seconds
    // AFTER the turn's Stop — that must not resurrect a finished session into a phantom
    // "Thinking…" island.
    if let p = prev, p.state == .thinking || p.state == .tool {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    }

case "compact":
    // Stash the trigger ("auto" mid-turn vs "manual" /compact) in the tool field so the
    // compact-restarted session-start above knows whether to keep the turn alive.
    writeState(.tool, label: "Compacting…", tool: "compact-\(str("trigger"))",
               startedAt: turnStart(), started: true)

case "permission":
    writeState(.permission, label: "Awaiting permission",
               startedAt: turnStart(), started: true)   // keep the turn clock; don't restart it on resume

case "denied":
    // A permission was denied — the model is about to respond to that, so fall back to thinking
    // right away instead of leaving the amber "Awaiting permission" up until the next event.
    if let p = prev, p.state == .permission || p.state.isWorking {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    }

case "notify":
    // ONLY an explicit permission prompt drives the island. The old version also matched any message
    // containing "permission"/"approve"/"allow", which fired on unrelated notifications — e.g. right
    // after you accepted, an "…allowed" notification re-opened "Awaiting permission" and caused the
    // open/close/timer churn. Match the exact notification type instead; ignore everything else.
    if str("notification_type").lowercased() == "permission_prompt" {
        writeState(.permission, label: "Awaiting permission",
                   startedAt: turnStart(), started: true)   // keep the turn clock; don't restart it
    }

case "stop":
    // A turn cannot truly end while a tool is still awaiting your approval. Some surfaces (the VS
    // Code extension) fire Stop when they suspend the turn to show a permission dialog; honoring it
    // would flash "Done", collapse the island, then re-open on accept — the churn you'd notice as
    // "it closed and reopened with a fresh timer". Ignore a Stop that lands mid-permission; the
    // real end (post -> stop) arrives after you accept.
    if prev?.state == .permission {
        debugLog("    ignored spurious stop while awaiting permission")
    } else {
        writeState(.done, label: "Done", startedAt: 0, started: true)
    }

case "stop-fail":
    if prev?.state == .permission {
        debugLog("    ignored spurious stop-fail while awaiting permission")
    } else {
        writeState(.error, label: "Error", startedAt: 0, started: true)
    }

case "session-end":
    StateStore.remove(provider: provider, sessionId: sessionId)

default:
    break
}

// The app quits itself when idle, so ANY sign of life must be able to bring it back — not just
// session-start. Without this, a session whose start the app missed (or that outlives an idle
// self-quit) would stay invisible for its whole life.
if kind != "session-end", !appIsRunning() {
    launchApp()
}

exit(0)
