# T-113: Install Tenon from inside Tenon
> The installer replaces the app it is running inside, so the step that quits Tenon hands
> off to a session the teardown cannot reach, instead of killing itself mid-copy.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-008` cli-control (`CLI-NFR-006` packaging order stays intact)

## Problem

`./install.sh` cannot be run from a Tenon pane, which is the only terminal a person working
on Tenon has open. At `install.sh:171-180` it quits the app by bundle id and kills every
process whose executable is `$DEST_APP/Contents/MacOS/Tenon` — correct for replacing a
bundle, fatal when the caller is a descendant of that process. The pane dies between the
kill and `rm -rf "$DEST_APP"`, so the install stops after the old copy is gone.

Measured, not assumed:

- This session's ancestry is `Tenon(37334) → login → fish → claude → zsh`, so a pane's
  shell really is a descendant of the app binary.
- `TerminalJobTerminator.sweep` (`Sources/TenonCore/TerminalJobTermination.swift:206-218`)
  picks victims with `ps -t <tty>` and signals their process groups, escalating SIGHUP →
  SIGKILL after 120 ms.
- In a real PTY, a `nohup`-backgrounded child is still listed by `ps -t <tty>` and is
  therefore killed; a child that called `setsid()` is not listed and survives. SIGKILL
  cannot be trapped, so leaving the controlling tty is the only thing that works.

## Approach

- Move the replace/sign/verify/launch half into `scripts/install-replace.sh`, taking its
  inputs through the environment. One implementation runs on both paths — the ordinary
  install calls it in the foreground, and a self-install calls the same file detached.
- `install.sh` walks its own ancestry for `$DEST_APP/Contents/MacOS/Tenon`. Finding it means
  the caller is inside the bundle being replaced, so the handoff runs under `setsid` with
  its output on a log file, and relaunch is forced regardless of `--launch`.
- Wait for the old app to actually exit before `rm -rf`, on both paths. The current script
  kills and immediately deletes; with the caller inside the app that race is no longer
  theoretical.
- `CLI-NFR-006` is a constraint on this refactor: the bundled-CLI checks must still run
  after `ditto` and after `codesign`, in that order.

## Criteria

- [x] `scripts/install-replace.sh` carries the replace/sign/verify/launch steps, called by
      both paths
- [x] Bundled-CLI verification still runs after ditto and after codesign (`CLI-NFR-006`)
- [x] Self-install is detected by ancestry, not by an env var a shell could inherit wrongly
- [x] The detached installer survives its pane being SIGKILLed
- [x] The old app is gone before its bundle is deleted
- [x] A self-install relaunches Tenon even without `--launch`
- [x] Running outside Tenon behaves exactly as before, log on stdout
- [x] Verified end to end through a staging install, which needs no self-replacement
- [x] `cli-control.prd.md` carries `CLI-NFR-009`, two scenarios, a decision, and a receipt

## For whoever lands real signing (T-114 wrote this note)

The ad-hoc sign/verify block T-114 has fixes for is no longer in `install.sh`. It is
`scripts/install-replace.sh`, unchanged in content and order. Both notes still apply there:
signing must run inside-out rather than `--deep --sign`, and `--options runtime` must stay
off the ad-hoc path, because Hardened Runtime's Library Validation cannot load this app's
three embedded frameworks under a signature with no Team ID.

## Limits, stated

- The detached path was proved against `Tenon Staging.app`, not `Tenon.app`. Verifying a
  real self-install means killing the session doing the verifying, so what is directly
  observed is every mechanism it depends on — ancestry detection from a genuine Tenon pane,
  `setsid` survival against a simulated sweep, and the full detached replace-and-reopen
  against staging — rather than the composed act itself.
- `install.sh` was edited while an earlier staging run was reading it, which is how bash
  loses its place in a script. That run was discarded and the verification above is from
  runs against the settled file.

## Owner / files (agent lock)

Released 2026-08-10 22:0x — session `e3b7fcdc` complete, no files held.
