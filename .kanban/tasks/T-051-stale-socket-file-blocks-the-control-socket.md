# T-051: A leftover socket file permanently blocks the control socket

> Kill the app without a clean shutdown and `/tmp/tenon-<uid>/tenon.sock` survives as a file.
> Every later launch fails to bind and starts with no control socket — silently. The CLI then
> reports "Tenon is not running" while Tenon is, in fact, running.

- **priority**: medium
- **effort**: S
- **found by**: session 247281cf while trying to re-verify T-050 against a live app.

## Evidence

`CLISocketServer.swift:143` — `guard withSocketAddress(path, { bind(fd, $0, $1) }) == 0 else {
close(fd); return nil }`. A stale path makes `bind` fail with `EADDRINUSE`, and the guard returns
before reaching the `unlink(path)` on the next line, which only runs when `listen` fails. So the
one cleanup that exists is behind the failure that does not happen.

Observed: a killed instance left `tenon.sock` dated 11:39; every launch afterwards ran with no
socket at all and no diagnostic, and `tenon-cli ping` insisted the app was not running.

## Why it is worth fixing rather than documenting

The CLI is the agent-first surface. Its failure mode here is a lie in the most confusing
direction — it names a specific missing file while the app is on screen — and the recovery
(`rm` a path the user has no reason to know about) is undiscoverable.

## Criteria
- [ ] A stale socket path is reclaimed on launch. **Reclaimed, not blindly unlinked**: a path
      that a *live* instance is listening on must still lose — that is the single-instance
      guarantee T-009 built. Connect first; unlink only when nothing answers
- [ ] Failing to create the control socket is reported, not swallowed. Today it returns nil and
      the app runs on as though nothing happened
- [ ] Asserted headlessly: a leftover file on the path does not prevent a fresh server from
      binding, and a live listener on the path still does
- [ ] A readiness check anywhere in scripts or docs uses a real connect, not `[ -S <path> ]` —
      that test is satisfied by the stale file and passes against a dead app

## Notes
Found while trying to reproduce T-050's original symptom end to end; it is why that re-verification
is recorded as not done.
