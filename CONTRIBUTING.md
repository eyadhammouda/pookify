# Contributing to Pookify

Thanks for your interest! Pookify is a small, dependency-free macOS app, so the
contribution loop is quick.

## Prerequisites

- macOS 14 or later
- A Swift 6 toolchain (Xcode 16+, or the matching Swift toolchain)
- No third-party dependencies — it builds offline with `swift build`

## Build & run

```bash
swift build                 # debug build of both targets
./scripts/build.sh          # assemble Pookify.app into ./build (ad-hoc signed)
./scripts/install.sh        # build + copy to /Applications + wire hooks + launch
```

You can preview every island state without running a real agent:

```bash
./scripts/demo.sh editing       # Claude "Editing"
./scripts/demo.sh cycle         # cycle through everything
./scripts/demo.sh stop          # tear the demo down
```

See [DEMO.md](DEMO.md) for the full list of states and options.

## Project layout

- `Sources/IslandCore/` — shared types and the on-disk state schema (linked by
  both the helper and the app). No AppKit/SwiftUI here.
- `Sources/island-hook/` — the tiny CLI Claude Code's hooks invoke; maps a hook
  event to a per-session state file. Must be fast and must never fail the agent.
- `Sources/Pookify/` — the menu-less `.accessory` app: polling, aggregation,
  the notch window, and the SwiftUI island.

The data flow is one-way and file-mediated: `island-hook` writes JSON snapshots
into `~/Library/Application Support/Pookify/state.d/`; the app polls that folder,
folds all live sessions into one decision, and renders the notch.

## Style

- Match the surrounding code: the existing comment density, naming, and idioms.
- The UI is `@MainActor`; the helper and the aggregator are stateless and
  dependency-free. Keep cross-process safety at the filesystem layer (atomic
  write + rename), not with locks.
- Keep `island-hook` best-effort: it must always `exit(0)` and never block or
  slow down a tool call.

## Pull requests

1. Branch off `main`.
2. Make sure `swift build` and `./scripts/build.sh` both succeed.
3. If you change behavior, update the README/DEMO and add a `CHANGELOG.md` entry
   under `[Unreleased]`.
4. Keep PRs focused; describe what changed and why.

## Adding a new agent

Pookify supports Claude Code only, but the plumbing stays provider-shaped. To
support another tool, add a `case` to `Provider`, an event→token table +
config adapter in `HookInstaller`, and any tool-name mappings in
`toolLabel(provider:tool:)`.

## Reporting bugs / requesting features

Open a GitHub issue using the templates. For anything security-sensitive, see
[SECURITY.md](SECURITY.md) instead of filing a public issue.
