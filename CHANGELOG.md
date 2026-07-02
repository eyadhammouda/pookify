# Changelog

All notable changes to Pookify are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Initial release: a Dynamic-Island-style status display for Claude Code, live
on the MacBook notch.

- Live activity labels — Thinking, Reading, Writing, Editing, Searching,
  Searching web, Browsing web, Running command, Planning, Delegating,
  Using MCP tool, Compacting and more — with the file name shown under file
  tools and a live turn timer that keeps running across permission waits.
- Amber "Awaiting permission" state that auto-opens once, stays dismissible,
  and resumes (never restarts) the turn clock when you approve.
- Multiple sessions fold into one island; a session awaiting permission
  outranks one that is merely working.
- Clawd the crab (default) or the official Claude spark as the working glyph —
  switchable from the island's right-click menu.
- Works with Claude Code in the terminal and in the VS Code extension; pausing
  or ending a session retracts the island promptly.
- The app launches itself when a session starts and quits itself when nothing
  is running — no daemon, no login item, no network, ever.
- Polished motion: the island always emerges slim from the notch and always
  de-expands before retracting; closing sweeps in from the sides.
- One-command install (`./scripts/install.sh`) and reversible uninstall; a dev
  demo harness previews every state and plays recordable stories (DEMO.md).
