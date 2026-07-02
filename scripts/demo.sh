#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Pookify — DEV DEMO HARNESS
#
# Preview EVERY state/activity using fake Claude Code sessions. It never
# touches your real ~/.claude config (runs ISLAND_NO_INSTALL=1).
#
# Usage:
#   ./scripts/demo.sh <activity>              Claude doing <activity>
#   ./scripts/demo.sh story1|story2|story3|story4   play a timed story (for recording)
#   ./scripts/demo.sh stories                 list the stories + what each shows
#   ./scripts/demo.sh multi                   two live sessions → permission outranks working
#   ./scripts/demo.sh open|close|blink|finish play the open/close animations
#   ./scripts/demo.sh closes                  play open → close five times, then stop
#   ./scripts/demo.sh cycle                   auto-play through everything
#   ./scripts/demo.sh stop                    close the demo + clean up
#
# Stories (3s countdown, then ~24s of story, then it retracts — good for screen recordings):
#   story1 / permission   think → read → edit → await permission → resume → done
#   story2 / basic        think → read → edit → run → done (no permission)
#   story3 / web          think → search web → browse → read → edit → done
#   story4 / everything   plan → read → search → edit → run → delegate → MCP → done
#   (prefix EXPAND=1 to keep the activity WORDS visible the whole time)
#
# Activities (every label the tool can show):
#   thinking  reading  searching  running  editing  writing  websearch  webfetch
#   planning  delegating  mcp  diagnostics  runcode  working
#   compacting  permission  done  error
#   (the slim bar shows the glyph + a status; the WORDS appear when expanded)
#
# Options (env — applied on (re)start; combine freely):
#   EXPAND=1              force the taller drop-down open so you can read the label
#   STYLE=spark|crab      Claude glyph (default crab — Clawd)
#   SHADE=<0..1 | #hex>   pill color (0 = pure black, the default)
#
# Examples:
#   ./scripts/demo.sh editing
#   EXPAND=1 ./scripts/demo.sh reading      # shows the file-name subtitle too
#   EXPAND=1 STYLE=spark ./scripts/demo.sh delegating
#   SHADE=0.06 ./scripts/demo.sh permission
#   ./scripts/demo.sh blink         # watch open/close
#   ./scripts/demo.sh cycle         # watch everything
#   ./scripts/demo.sh stop
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "demo.sh: failed to cd to the repo root" >&2; exit 1; }

REPO="$(pwd)"
SD="$HOME/Library/Application Support/Pookify/state.d"
RUN="$HOME/Library/Application Support/Pookify/.demo"
APP="$REPO/.build/debug/Pookify"
mkdir -p "$SD" "$RUN"

# Kill the keep-alive sleep (so Ctrl-C out of a loop doesn't orphan it).
kill_sleep() { [ -f "$RUN/sleep.pid" ] && kill "$(cat "$RUN/sleep.pid")" 2>/dev/null; rm -f "$RUN/sleep.pid"; }
# Minimal JSON string escaping (backslash + double quote) for interpolated paths.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

live_pid() {
  if [ -f "$RUN/sleep.pid" ] && kill -0 "$(cat "$RUN/sleep.pid")" 2>/dev/null; then
    cat "$RUN/sleep.pid"
  else
    nohup sleep 100000 >/dev/null 2>&1 &
    echo $! | tee "$RUN/sleep.pid"
  fi
}
app_running() { pgrep -x Pookify >/dev/null 2>&1; }
ensure_app() {
  app_running && return 0
  [ -x "$APP" ] || { echo "Building…"; swift build >/dev/null 2>&1 || { swift build; exit 1; }; }
  ISLAND_NO_INSTALL=1 \
  ISLAND_CLAUDE_STYLE="${STYLE:-crab}" \
  ISLAND_PILL="${SHADE:-}" \
  ISLAND_FORCE_EXPAND="${EXPAND:-}" \
  nohup "$APP" >/dev/null 2>&1 &
  echo $! > "$RUN/app.pid"
  sleep 0.6
}

# write_state <state> <label> <tool> <startedSecondsAgo> [detail]
write_state() {
  local lp now st
  lp="$(live_pid)"; now="$(date +%s)"; st=0
  [ "${4:-0}" -gt 0 ] 2>/dev/null && st=$((now - $4))
  rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"%s","label":"%s","tool":"%s","project":"pookify","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
    "$1" "$2" "${3:-}" "$(json_escape "$REPO")" "$lp" "$st" "$now" "${5:-}" > "$SD/claude-demo.json"
}
write_idle() {
  local lp now; lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"idle","label":"","tool":"","project":"","cwd":"%s","model":"","pid":%s,"startedAt":0,"ts":%s,"started":false}' \
    "$(json_escape "$REPO")" "$lp" "$now" > "$SD/claude-demo.json"
}

# ── Story mode: play a realistic, timed sequence of states for recording ──────
# scene_state writes an ABSOLUTE startedAt (unlike write_state's "seconds ago"),
# so the live timer counts up continuously across a whole story — including
# straight through an "Awaiting permission" pause, exactly like a real turn.
scene_state() { # state label tool startAbs [detail]
  local lp now; lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"%s","label":"%s","tool":"%s","project":"pookify","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
    "$1" "$2" "${3:-}" "$(json_escape "$REPO")" "$lp" "${4:-0}" "$now" "${5:-}" > "$SD/claude-demo.json"
}

# play_story <replay-name> <title> <step...>   step = "secs|state|label|tool|detail"
# A `done` step shows the check (timer hidden); the story always ends by retracting.
play_story() {
  local replay="$1" title="$2"; shift 2
  if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
  echo "▸ story '$replay': $title"
  echo "  (tip: prefix EXPAND=1 to keep the words visible while recording; STYLE=spark|crab to pick the glyph)"
  # A short runway so you can start/arrange your screen recording before the island emerges.
  echo -n "  starting in 3"; sleep 1; echo -n " … 2"; sleep 1; echo -n " … 1"; sleep 1; echo " … go"
  local START; START="$(date +%s)"
  local first="$1"; shift
  local secs st label tool detail
  IFS='|' read -r secs st label tool detail <<< "$first"
  # Write the first state BEFORE launching so the very first poll sees it (a force-expand launch
  # would otherwise reset to collapsed on the first empty tick).
  scene_state "$st" "$label" "$tool" "$START" "$detail"
  ensure_app
  sleep "$secs"
  for step in "$@"; do
    IFS='|' read -r secs st label tool detail <<< "$step"
    case "$st" in
      done) scene_state done "Done" "" 0 "" ;;
      error) scene_state error "Error" "" 0 "" ;;
      idle) write_idle ;;
      *)    scene_state "$st" "$label" "$tool" "$START" "$detail" ;;
    esac
    sleep "$secs"
  done
  write_idle                       # retract into the notch (de-expands first, then slides in)
  sleep 1.2                        # let the close animation finish before we return
  echo "  ✓ finished. replay: ./scripts/demo.sh $replay   |   stop: ./scripts/demo.sh stop"
}

# The named stories (each ~24s, plays once, then retracts).
story() {
  case "$1" in
    story1|permission)
      play_story story1 "think → read → edit → await permission → resume → done" \
        "3|thinking|Thinking…||" \
        "4|tool|Reading|Read|sidebar.tsx" \
        "4|tool|Editing|Edit|sidebar.tsx" \
        "5|permission|Awaiting permission|Bash|" \
        "4|tool|Running command|Bash|" \
        "4|done|Done||" ;;
    story2|basic)
      play_story story2 "think → read → edit → run → done (no permission)" \
        "4|thinking|Thinking…||" \
        "5|tool|Reading|Read|sidebar.tsx" \
        "6|tool|Editing|Edit|AppController.swift" \
        "5|tool|Running command|Bash|" \
        "4|done|Done||" ;;
    story3|web)
      play_story story3 "think → search web → browse → read → edit → done" \
        "3|thinking|Thinking…||" \
        "5|tool|Searching web|WebSearch|" \
        "4|tool|Browsing web|WebFetch|" \
        "4|tool|Reading|Read|notch-spec.md" \
        "4|tool|Editing|Edit|README.md" \
        "4|done|Done||" ;;
    story4|everything)
      play_story story4 "the works: plan → read → search → edit → run → delegate → MCP → done" \
        "2|thinking|Thinking…||" \
        "2.4|tool|Planning|TodoWrite|" \
        "2.4|tool|Reading|Read|SessionAggregator.swift" \
        "2.4|tool|Searching|Grep|" \
        "3|tool|Editing|Edit|SessionAggregator.swift" \
        "3|tool|Running command|Bash|" \
        "2.4|tool|Delegating|Task|" \
        "2.4|tool|Using MCP tool|mcp__server__tool|" \
        "4|done|Done||" ;;
    *) echo "Unknown story '$1'. Try: story1 (permission), story2 (basic), story3 (web), story4 (everything)."; exit 1 ;;
  esac
}

# resolve <activity>  -> sets STATE, LABEL, TOOL, AGO, DETAIL (returns 1 if unknown)
resolve() {
  local a="$1"; TOOL=""; AGO=0; DETAIL=""
  case "$a" in
    thinking)   STATE=thinking; LABEL="Thinking…"; AGO=8 ;;
    reading)    STATE=tool; LABEL="Reading"; TOOL=Read; AGO=12; DETAIL="sidebar.tsx" ;;
    searching)  STATE=tool; LABEL="Searching"; TOOL=Grep; AGO=15 ;;
    running)    STATE=tool; LABEL="Running command"; TOOL=Bash; AGO=72 ;;
    editing)    STATE=tool; LABEL="Editing"; TOOL=Edit; AGO=45; DETAIL="AppController.swift" ;;
    writing)    STATE=tool; LABEL="Writing"; TOOL=Write; AGO=20; DETAIL="NewFile.swift" ;;
    websearch)  STATE=tool; LABEL="Searching web"; TOOL=WebSearch; AGO=18 ;;
    webfetch)   STATE=tool; LABEL="Browsing web"; TOOL=WebFetch; AGO=10 ;;
    planning)   STATE=tool; LABEL="Planning"; TOOL=TodoWrite; AGO=6 ;;
    delegating) STATE=tool; LABEL="Delegating"; TOOL=Task; AGO=30 ;;
    mcp)        STATE=tool; LABEL="Using MCP tool"; TOOL="mcp__server__tool"; AGO=14 ;;
    diagnostics) STATE=tool; LABEL="Checking diagnostics"; TOOL=mcp__ide__getDiagnostics; AGO=8 ;;
    runcode)    STATE=tool; LABEL="Running code"; TOOL=mcp__ide__executeCode; AGO=9 ;;
    working)    STATE=tool; LABEL="Working…"; TOOL=SomeTool; AGO=12 ;;
    compacting) STATE=tool; LABEL="Compacting…"; AGO=5 ;;
    permission) STATE=permission; LABEL="Awaiting permission"; TOOL=Bash; AGO=0 ;;
    done)       STATE=done; LABEL="Done"; AGO=0 ;;
    error)      STATE=error; LABEL="Error"; AGO=0 ;;
    *) return 1 ;;
  esac
}

show() { # activity
  if ! resolve "$1"; then
    echo "Unknown activity '$1'. Run './scripts/demo.sh help' for the list."; exit 1
  fi
  if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
  # Write the session BEFORE launching so the very first poll sees it visible (otherwise a
  # force-expand launch gets reset to collapsed on the first empty tick).
  write_state "$STATE" "$LABEL" "$TOOL" "$AGO" "$DETAIL"
  ensure_app
  echo "▸ $1  →  \"$LABEL\"  (STYLE=${STYLE:-crab} SHADE=${SHADE:-black} EXPAND=${EXPAND:-0})"
  echo "  next: ./scripts/demo.sh <activity>   |   stop: ./scripts/demo.sh stop"
}

# The full activity set, used by `cycle`.
CLAUDE_ACTS="thinking reading searching running editing writing websearch webfetch planning delegating mcp diagnostics runcode compacting working permission done error"

cmd="${1:-help}"
case "$cmd" in
  stop)
    for p in blink finish cycle story; do pkill -f "demo.sh $p" 2>/dev/null; done
    pkill -x Pookify 2>/dev/null
    [ -f "$RUN/sleep.pid" ] && kill "$(cat "$RUN/sleep.pid")" 2>/dev/null
    rm -rf "$SD"/*.json "$RUN" 2>/dev/null
    echo "Demo stopped." ;;

  story1|story2|story3|story4|permission|basic|web|everything)
    story "$cmd" ;;

  stories)
    echo "Recordable stories (3s countdown, then ~24s of story, then it retracts):"
    echo "  story1 / permission   think → read → edit → await permission → resume → done"
    echo "  story2 / basic        think → read → edit → run → done (no permission)"
    echo "  story3 / web          think → search web → browse → read → edit → done"
    echo "  story4 / everything   plan → read → search → edit → run → delegate → MCP → done"
    echo
    echo "Run:   ./scripts/demo.sh story1        (add EXPAND=1 to keep the words visible)"
    echo "       EXPAND=1 STYLE=spark ./scripts/demo.sh story3" ;;

  open)
    write_idle; ensure_app; sleep 0.6
    write_state thinking "Thinking…" "" 1
    echo "OPEN — the slim bar emerges from the notch (left↔right)." ;;

  close)
    ensure_app; write_idle
    echo "CLOSE — the slim bar retracts into the notch." ;;

  closes)
    # Play open → close five times in a row, then stop — for judging the close animation.
    ensure_app
    echo "Playing open → close 5 times…"
    for i in 1 2 3 4 5; do
      write_state thinking "Thinking…" "" 1; sleep 2.2
      write_idle; sleep 2.2
      echo "  close #$i"
    done
    echo "Done. Replay: ./scripts/demo.sh closes   |   stop: ./scripts/demo.sh stop" ;;

  blink)
    ensure_app
    echo "Open→close loop (Ctrl-C to stop the loop; 'stop' to close the app)…"
    trap 'kill_sleep; exit 0' INT
    while true; do write_state thinking "Thinking…" "" 1; sleep 3; write_idle; sleep 2.5; done ;;

  finish)
    ensure_app
    echo "The real 'Claude is done' flow: working → done → retract (loops; Ctrl-C to stop)…"
    trap 'kill_sleep; exit 0' INT
    while true; do
      resolve running; write_state "$STATE" "$LABEL" "$TOOL" 5; sleep 3
      resolve done;    write_state "$STATE" "$LABEL" "$TOOL" 0; sleep 2.5
      write_idle; sleep 2.5
    done ;;

  cycle)
    ensure_app
    echo "Cycling every activity (Ctrl-C to stop the loop; 'stop' to close)…"
    trap 'kill_sleep; exit 0' INT
    while true; do
      for a in $CLAUDE_ACTS; do resolve "$a"; write_state "$STATE" "$LABEL" "$TOOL" "$AGO" "$DETAIL"; sleep 2.6; done
      write_idle; sleep 1.5
    done ;;

  multi)
    # Two live sessions at once → the island folds them into one and shows the higher-priority
    # state: the permission request outranks the merely-working session.
    lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
    if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
    printf '{"schema":1,"provider":"claude","sessionId":"multiA","state":"tool","label":"Editing","tool":"Edit","project":"alpha","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true}' \
      "$(json_escape "$REPO")" "$lp" "$((now-30))" "$now" > "$SD/claude-multiA.json"
    printf '{"schema":1,"provider":"claude","sessionId":"multiB","state":"permission","label":"Awaiting permission","tool":"Bash","project":"beta","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":0,"ts":%s,"started":true}' \
      "$(json_escape "$REPO")" "$lp" "$now" > "$SD/claude-multiB.json"
    ensure_app
    echo "▸ Two live sessions: one Editing + one Awaiting permission."
    echo "  → The island shows the permission (amber, auto-opens) — permission outranks working." ;;

  help|-h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;

  claude)
    show "${2:-thinking}" ;;

  *)
    show "$cmd" ;;
esac
