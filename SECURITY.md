# Security policy

Pookify runs entirely on your Mac, makes no network calls, and collects no
data. Its trust boundary is small, but it does two privileged-feeling things:

- It runs a compiled helper (`island-hook`) from Claude Code's hooks.
- It edits `~/.claude/settings.json` (backing it up to `*.bak-pookify` before
  the first edit).

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Preferred: GitHub's private vulnerability reporting
  (the repository's **Security → Report a vulnerability** tab).
- You'll get an acknowledgement as soon as possible, and a fix or mitigation
  will be coordinated before any public disclosure.

When reporting, include the macOS version, the Claude Code version, and the
steps to reproduce.

## Scope notes

- State files live under `~/Library/Application Support/Pookify/state.d/` with
  owner-only permissions (`0700` dir, `0600` files) and contain a session's
  state, a short tool label, the project folder name, the working directory, the
  model name, and the agent's process id.
- The installer refuses to overwrite a config file it can't parse as a JSON
  object, and only writes config when `~/.claude` already exists.
- Hook commands are written with the helper path single-quoted for the shell.

## Supported versions

Pookify is pre-1.0; only the latest release/`main` receives fixes.
