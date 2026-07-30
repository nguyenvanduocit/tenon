# Tenon

Tenon is the human supervision layer for people running parallel CLI agents
such as Codex and Claude Code.

It preserves shared context, directs scarce human attention, and makes parallel
work understandable, verifiable, and steerable. Agents keep running in their
own CLI harnesses and real PTYs. Tenon provides the native workspace in which a
person can answer:

- what materially changed since the last look;
- what requires human judgment now;
- what evidence supports each claim;
- which work is blocked, stale, drifting, or conflicting;
- what can safely wait.

The interaction model is intentionally small:

- the left sidebar switches workspaces;
- each workspace owns tabs;
- a new tab starts as one full-size libghostty terminal;
- each tab is a 12 × 12 spatial canvas of movable, swappable, resizable slots;
- terminal, files, changes, docs, web preview, and plugin views can share that
  canvas.

Tenon keeps the terminal at the center while bringing the tools needed during a
coding session into the same window. Agent harnesses own planning, spawning,
scheduling, and execution. Tenon owns the operator's situation awareness and
return path to raw evidence.

The supervision direction, Attention Inbox wedge, and falsifiable product
metrics are documented in
[`docs/research-human-agent-supervision.md`](docs/research-human-agent-supervision.md).

## Repository

- [`VISION.md`](VISION.md) — current product and architecture contract.
- [`poc/`](poc/) — the current native app. The directory name is historical.
- [`prototypes/spatial-layout/`](prototypes/spatial-layout/) — the structural
  design contract for component hierarchy, regions, and interactions.
- [`docs/`](docs/) — research and design history.

## Build

Tenon requires macOS 14+, Xcode, XcodeGen 2.45.4+, and Bun is not required for
the native app.

```bash
cd poc
./scripts/setup-ghosttykit.sh
xcodegen generate
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  build
open .build/xcode/Build/Products/Debug/Tenon.app
```

For a UI smoke test without starting a PTY:

```bash
TENON_STUB_TERMINAL=1 \
TENON_WORKSPACE_PATH=/path/to/project \
  .build/xcode/Build/Products/Debug/Tenon.app/Contents/MacOS/Tenon
```

`TENON_WORKSPACE_PATH` selects the initial workspace and the working directory
of its terminal surfaces. Without it, Tenon uses a meaningful launch directory
and falls back to the user's home directory when LaunchServices starts the app
at `/`.

See [`poc/README.md`](poc/README.md) for controls, tests, the plugin runtime,
and the libghostty packaging details.

Status: pre-alpha. The native shell, spatial workspace model, libghostty
embedding, built-in slot surfaces, and plugin runtime are running and covered
by 159 non-UI tests plus 6 black-box macOS UI flows. Layout persistence and
production hardening are still ahead. The Attention Inbox, evidence-linked
context capsules, structured agent signals, and safe-fan-out measurements are
the next product direction; they are not implemented runtime capabilities.
