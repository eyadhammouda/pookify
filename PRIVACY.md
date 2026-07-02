# Privacy

Pookify is fully local and makes **no network calls**.

- No telemetry, no analytics, no accounts. Nothing is ever sent anywhere.
- It reads and writes only on your Mac:
  - Per-session status files under `~/Library/Application Support/Pookify/state.d/` (state, a short tool label, the project folder name, and the agent's process id, used to tell when a session ends). These are deleted as sessions end.
  - Hook entries it adds to `~/.claude/settings.json`, backed up to `settings.json.bak-pookify` before the first edit. `./scripts/uninstall.sh` removes them.
- It does not read your prompts, code, or conversation transcripts.

That's it.
