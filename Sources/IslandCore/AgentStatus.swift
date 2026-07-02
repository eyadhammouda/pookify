import Foundation

/// Which coding agent a session belongs to. Claude Code is the only supported agent; the case
/// is kept as an enum (and in the on-disk JSON) so adding another agent later stays cheap.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude

    public var displayName: String { "Claude Code" }

    /// Brand accent as sRGB components (kept UI-framework-free here; the UI maps it to a color).
    /// Anthropic's official "Orange" #d97757.
    public var accentRGB: (r: Double, g: Double, b: Double) { (0.851, 0.467, 0.341) }
}

/// The normalized lifecycle state of a single session, derived from hook events.
/// Ordered loosely by how much it deserves the user's attention.
public enum AgentState: String, Codable, Sendable {
    case idle        // session open, nothing happening
    case thinking    // model is reasoning between tools
    case tool        // running a tool (see `label`/`tool` for which)
    case permission  // blocked, awaiting the user's approval
    case done        // a turn just finished (transient → collapses to idle)
    case error       // a turn ended on an error (transient)

    /// Higher = more important to surface when several sessions are live.
    public var priority: Int {
        switch self {
        case .permission:        return 3
        case .tool, .thinking:   return 2
        case .error, .done:      return 1
        case .idle:              return 0
        }
    }

    public var isWorking: Bool { self == .thinking || self == .tool }
}

/// One session's state, written by `island-hook` and read by the app. This is the entire
/// on-disk contract — a flat, human-readable JSON file per session.
public struct SessionSnapshot: Codable, Sendable {
    public var schema: Int
    public var provider: Provider
    public var sessionId: String
    public var state: AgentState
    public var label: String      // human label, e.g. "Editing", "Awaiting permission"
    public var tool: String       // raw tool name, e.g. "Edit" (empty when not in a tool)
    public var project: String    // basename of cwd
    public var cwd: String
    public var model: String
    public var pid: Int32         // the agent process; kill(pid,0) drives liveness (0 = unknown)
    public var startedAt: Double  // unix seconds the current turn began (0 = no active turn)
    public var ts: Double         // unix seconds this snapshot was written
    public var started: Bool      // true once the session had real activity (a prompt/tool)
    public var toolEndsAt: Double // for a `tool` state: 0 = still running; >0 = finished, keep the
                                  // label until this time, then the reader treats it as thinking
    public var detail: String     // small context under the label, e.g. the file basename ("App.swift")
    public var promptId: String   // Claude Code's per-turn id; identifies which turn `startedAt`
                                  // belongs to, so the clock survives events re-fired within a turn
    public var transcript: String // the session's transcript path. The VS Code extension fires NO
                                  // hook when the user pauses/interrupts, so the transcript's final
                                  // entry (the interruption marker) is the only way to notice

    public init(schema: Int = Island.stateSchema,
                provider: Provider,
                sessionId: String,
                state: AgentState,
                label: String = "",
                tool: String = "",
                project: String = "",
                cwd: String = "",
                model: String = "",
                pid: Int32 = 0,
                startedAt: Double = 0,
                ts: Double = 0,
                started: Bool = false,
                toolEndsAt: Double = 0,
                detail: String = "",
                promptId: String = "",
                transcript: String = "") {
        self.schema = schema
        self.provider = provider
        self.sessionId = sessionId
        self.state = state
        self.label = label
        self.tool = tool
        self.project = project
        self.cwd = cwd
        self.model = model
        self.pid = pid
        self.startedAt = startedAt
        self.ts = ts
        self.started = started
        self.toolEndsAt = toolEndsAt
        self.detail = detail
        self.promptId = promptId
        self.transcript = transcript
    }

    /// Tolerate older/newer files: unknown provider/state decode to safe defaults rather than
    /// failing the whole read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema    = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        provider  = (try? c.decode(Provider.self, forKey: .provider)) ?? .claude
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        state     = (try? c.decode(AgentState.self, forKey: .state)) ?? .idle
        label     = (try? c.decode(String.self, forKey: .label)) ?? ""
        tool      = (try? c.decode(String.self, forKey: .tool)) ?? ""
        project   = (try? c.decode(String.self, forKey: .project)) ?? ""
        cwd       = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        model     = (try? c.decode(String.self, forKey: .model)) ?? ""
        pid       = (try? c.decode(Int32.self, forKey: .pid)) ?? 0
        startedAt = (try? c.decode(Double.self, forKey: .startedAt)) ?? 0
        ts        = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        started   = (try? c.decode(Bool.self, forKey: .started)) ?? false
        toolEndsAt = (try? c.decode(Double.self, forKey: .toolEndsAt)) ?? 0
        detail    = (try? c.decode(String.self, forKey: .detail)) ?? ""
        promptId  = (try? c.decode(String.self, forKey: .promptId)) ?? ""
        transcript = (try? c.decode(String.self, forKey: .transcript)) ?? ""
    }
}

/// Maps a raw Claude Code tool name to a short, friendly label for the pill.
/// Covers today's tool names plus older ones (Task, MultiEdit, …) so any CLI version reads well.
public func toolLabel(provider: Provider, tool: String) -> String {
    let claude: [String: String] = [
        "Bash": "Running command", "BashOutput": "Running command", "KillShell": "Running command",
        "KillBash": "Running command", "PowerShell": "Running command", "SlashCommand": "Running command",
        "Monitor": "Running command", "TaskOutput": "Running command", "TaskStop": "Running command",
        "Edit": "Editing", "MultiEdit": "Editing", "NotebookEdit": "Editing", "Write": "Writing",
        "Read": "Reading", "Grep": "Searching", "Glob": "Searching",
        "WebFetch": "Browsing web", "WebSearch": "Searching web",
        "Task": "Delegating", "TaskCreate": "Delegating",
        "Agent": "Delegating", "SendMessage": "Delegating", "Workflow": "Delegating",
        "TodoWrite": "Planning", "ExitPlanMode": "Planning", "exit_plan_mode": "Planning",
        "EnterPlanMode": "Planning",
        "ToolSearch": "Preparing tools", "Skill": "Running skill",
        "AskUserQuestion": "Asking a question",
        "mcp__ide__getDiagnostics": "Checking diagnostics", "mcp__ide__executeCode": "Running code",
    ]
    if let hit = claude[tool] { return hit }
    if tool.hasPrefix("mcp__") { return "Using MCP tool" }   // mcp__<server>__<tool>
    return "Working…"
}
