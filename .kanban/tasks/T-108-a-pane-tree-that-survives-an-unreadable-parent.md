# T-108: A pane tree that survives an unreadable parent
> The Resource Monitor attributes zero processes to every pane because each pane's tree hangs below a setuid-root `login` the sampler cannot read, and an unreadable process still hides its children from root selection.

- **priority**: critical
- **effort**: S

## The defect, measured

Ghostty spawns every pane through `/usr/bin/login` (`-r-sr-xr-x 1 root wheel`), which runs as
**UID 0** while Tenon runs as UID 501. `proc_pidinfo(PROC_PIDTBSDINFO)` on it returns
`rc=0, errno=1` (EPERM). A probe against the two live panes of session `2c553190`:

```
=== /dev/ttys000  device=268435456
  attached: [37402, 37403, 40098, 40225, 40226, 40230, 40598, 40782, 58743, 70095, 71818]
  pid 37402: bsdInfo FAILED rc=0 errno=1
  pid 37403 ppid=37402 root=false comm=fish
  pid 40098 ppid=37403 root=false comm=claude ...
  roots: []
```

`DarwinProcessSampler.sweep` builds `attachedSet` from `proc_listpids` (every attached PID,
readable or not), then calls a process a root when its parent is **not** in that set. `login`
is in the set and is never itself read, so it is simultaneously invisible as a root and
present as a parent — it shadows `fish`, `fish` shadows nothing because it is already
disqualified, and `rootPIDs` comes out empty. The BFS never runs. Every pane reports
unavailable, and `unreadableCount` lands on exactly one `login` per pane, which is the
`partial, 2 processes unreadable` banner the user photographed.

The permission failure is the trigger; the defect is that root selection reads the
*enumerated* set where it means the *readable* set. Any unreadable attached process — a dead
one mid-sweep, a future setuid helper — cuts the same branch.

`TerminalProcessProjectionTests` misses it because its fixtures spawn processes directly, so
the parent is always readable. The rule is also unreachable from `TenonCoreTests` today,
which contradicts the sampler's own stated contract ("it reports what the kernel said and
decides nothing" — `DarwinProcessSampler.swift:10-13`): root selection is a decision living
in the shell layer.

## Criteria
- [x] A readable process whose parent is unreadable begins its pane's tree, so a `login`-rooted pane reports its shell and every descendant.
- [x] Root selection is a pure rule in `TenonCore`, asserted without a process tree, covering: unreadable parent, parent outside the terminal, sibling roots, a parent/child pair where both are readable, and a parent cycle.
- [x] An unreadable process found while surveying a terminal's attachments no longer counts toward `unreadableCount`; a process lost inside the walked tree still does. Healthy panes stop reporting `partial` forever.
- [x] The shipped `DarwinProcessSampler` was run against this machine's two real panes and returned 20 processes, `unreadable=0`, `shared=0`, every row owned — against 0 processes and `unreadable=2` before.
- [x] PRD-016 records the corrected behaviour with a dated receipt, and `.feature` carries two new `@req-drm-fr-025` scenarios.

## A second defect of the same class, found while proving the first

The walk skipped `childPIDs` for any process it could not read, so one unreadable process
mid-tree deleted everything beneath it — a `sudo` (`-r-s--x--x root wheel`) inside a pane
would take its whole subtree with it. Measured: `proc_listchildpids` answers for an EPERM
process (`childPIDs(37402) == [37403]` with `readable=false`), so children are now queued
before the read is attempted. Fixed in the same change.

## Honest limits

- **No setuid-parent case in the automated suite.** macOS ships no password-free setuid-root
  process a test can spawn under its own pty (`/sbin/ping` is not setuid here; `sudo` needs a
  credential), so the sampler-level behaviour rests on the pure rule's coverage plus the live
  run recorded above. The pure rule states the production case exactly and was red before.
- The monitor popover still has never been photographed — it is title-bar chrome and
  `PaneViewSnapshotWriter` renders pane content only. Inherited from T-100.

## Owner / files (agent lock)

Session `2c553190` — **RELEASED 2026-08-10 16:1x, holds nothing.** Every file below is free.
WIP was temporarily 3 (T-090, T-071, this) for a user-directed critical fix; every file was
already released by T-100 and uncontested throughout. Not committed.

- `Sources/TenonCore/ProcessTelemetry.swift` — `AttachedProcess`, `TerminalProcessTree`
- `Sources/TenonApp/DarwinProcessSampler.swift` — survey/roots/walk
- `Tests/TenonCoreTests/TerminalProcessTreeTests.swift` (NEW, 7 tests)
- `docs/prds/diagnostics-and-resource-monitor.prd.md`, `.feature`
- `.kanban/board.md`, this file

`TerminalProcessProjectionTests.swift` was claimed and **not** edited — see Limits.

Requirements: `DRM-FR-025` (stable TTY provenance and reachable child traversal),
`DRM-FR-035` (permission failure preserves healthy rows).
