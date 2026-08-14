# T-159: A command longer than the PTY input queue silently loses its Enter
> `terminal.open.v1`/`terminal.run.v1` write the command into the PTY before the shell exists; macOS's canonical input queue caps at 1024 bytes (`MAX_INPUT`), so a longer command is truncated and its trailing newline discarded — the pane shows the command "typed" but it never executes.
- **priority**: high
- **effort**: M

## Evidence (2026-08-14, live app)

Production failure — tab `41718934-4567-41E0-9E16-CFB4CED452C4`, pane `CD5519F8-BC2C-4EF0-A728-AAE323891075`:
- An `agent.command.v1`-composed claude launch (~1.6 KB, whole prompt inline as one quoted argument — `AgentLaunchCommand.swift:89-91`) went through `terminal.open.v1`.
- The pane's viewport shows the kernel's canonical-mode echo of the command **before** login's `Last login:` banner — proof the bytes hit the PTY before the shell was spawned.
- fish's line buffer holds exactly **1023 bytes** of that command; the tail — including the closing quote and the `"\n"` appended at `TerminalIntentProvider.swift:238` — was silently dropped by the kernel. Command sits at the prompt, unexecuted.
- A follow-up `terminal.write.v1` retry (623 bytes, no trailing `\r`) appended to the same unexecuted line.

Controlled reproduction (same session):
- `terminal.open.v1` with a 20-byte command → shell executed it (typeahead survives when the whole command + newline fits the queue). This is why tests and daily use never catch it.
- `terminal.open.v1` with a ~1330-byte command → fish buffer holds exactly **1024 bytes**, tail + newline gone, marker file never created. Same screen shape as the production pane, byte for byte at the boundary.

## Mechanism

1. `TerminalIntentProvider.open/run` → `SurfacePool.sendTextWhenReady(command + "\n")` queues until the pane materialises (`SurfacePool.swift:295-301`, flush at `152-153`).
2. `GhosttySurface.createSurface()` flushes `pendingInput` immediately after `ghostty_surface_new` (`GhosttySurface.swift:752-758`) — the child shell has not run yet, so nothing is reading the slave side.
3. With no reader, the pty line discipline (canonical mode) buffers at most `MAX_INPUT` = 1024 bytes and **discards** the rest without error. Everything ≤ 1024 survives as typeahead; byte 1025 onward — usually including the `"\n"` — is gone.

## Criteria
- [ ] A `terminal.open.v1`/`terminal.run.v1` command of any accepted length is delivered whole and executes: delivery waits for shell readiness (first OSC 7 / title report, with a bounded fallback) instead of firing at surface creation — or, if a byte bound is chosen instead, an over-bound command is refused with a clear `invalidInput` reason, never silently truncated.
- [ ] `agent.command.v1` composition and its consumers stay working for long prompts (today it inlines the entire prompt as one argument, which is what crossed the limit).
- [ ] Regression coverage pins the chosen behaviour in `TerminalIntentProviderTests` (and a live-PTY probe if delivery-after-ready is chosen — the stub surface cannot see kernel truncation).
- [ ] `terminal.prd.md` records the decision and the constraint.

## Notes
- Root-caused and reproduced by CLI-investigation session 2026-08-14 (report in session transcript). No source edits made; CLI layer is a thin wire client and cannot fix this — the fix is host-side (TenonApp), files unheld today but check `Doing` first.
- Safe workaround for orchestrators until fixed: keep `command` under ~1000 bytes — write long prompts to a file and open with `claude ... "$(cat /path/prompt.txt)"`; or open the pane with no command, wait for the prompt, then `terminal.write.v1` ending in `\n` (`tenon-cli send --enter`).
