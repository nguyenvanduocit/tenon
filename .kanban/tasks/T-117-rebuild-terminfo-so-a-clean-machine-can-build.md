# T-117: Rebuild terminfo so a clean machine can build

> `project.yml` requires `Resources/terminfo`, `.gitignore` excludes it, and no script
> creates it. It exists on exactly one laptop. Every CI run since 2026-08-07 has died on
> that directory, and a tagged release would die at the same line.

- **priority**: critical
- **effort**: S
- **prd**: TENON-PRD-015 (ENQ-FR-040 new, ENQ-NFR-012 reproducibility)

## What is actually broken

Three facts that only fail when combined:

| Where | What it says |
|---|---|
| `project.yml:95` | `Resources/terminfo` is a required source directory of target `Tenon` |
| `.gitignore:19` | `/Resources/` — so `git ls-files Resources/` returns **0 files** |
| `scripts/setup-ghosttykit.sh:153` | reconstructs `Resources/ghostty` only; terminfo is never mentioned |

On this laptop `Resources/terminfo/{67/ghostty,78/xterm-ghostty}` has sat there since
**23 Jul 02:53**, hand-placed, untracked, and unreproducible. Anywhere else, `xcodegen
generate` stops at spec validation:

```
Spec validation error: Target "Tenon" has a missing source directory ".../Resources/terminfo"
```

That is the whole of the CI failure — 5 of 5 runs, `macos-ci.yml`, every push since
2026-08-07. `scripts/release.sh:54` calls the same `xcodegen generate`, so pushing `v0.1.0`
today fails before it reaches the signing step. The successful 0.1.0 notarization recorded
in T-114 was produced locally, on the one machine that has the directory.

`docs/development.md:31` already claims setup "downloads the xcframework, shell
integration, and terminfo". The doc describes the intent; the script never implemented it.

## Where terminfo has to come from

Upstream keeps the entry as Zig source (`src/terminfo/ghostty.zig` in `muxy-app/ghostty`),
and the pinned `build-2026-04-29` release ships only two assets — the xcframework and
`GhosttyKit-resources.tar.gz`, whose payload is `ghostty/{shell-integration,themes}` with no
terminfo in it. There is nothing to download, and this repo's rule is that zig never runs
here.

So the entry is checked in as terminfo **source text** and compiled by the setup script.
Two measurements justify that before any code changed:

- The shipped entry carries **268 capabilities; the upstream Zig definition declares 268**,
  and the two sets are equal — no capability missing, none extra. So the binary on this
  laptop really is the pinned Ghostty's entry, not some older system copy.
- `tic -x` over the decompiled source reproduces **byte-identical** `67/ghostty` and
  `78/xterm-ghostty`. Compiling is provably lossless here, so the committed text is the
  same artifact in a form a human can diff.

## Criteria

- [x] A clean checkout with no `Resources/` at all can run `scripts/setup-ghosttykit.sh`
      then `xcodegen generate` with no spec validation error
- [x] The compiled entry is byte-identical to the one that shipped in 0.1.0
- [x] Terminfo is rebuilt even when GhosttyKit is already installed and verified —
      `installation_is_current` must not short-circuit past it
- [x] `scripts/test-setup-ghosttykit.sh` covers the new function, red before green
- [x] `docs/development.md` says what setup does now, rather than what it never did
- [x] PRD-015 carries the requirement (ENQ-FR-040) and four dated receipts

## Evidence

Red first, for the intended reason: the new assertions failed with `install_terminfo:
command not found` (exit 127) before the function existed, then passed.

The clean room is the receipt that matters, because it reproduces what CI does rather than
approximating it. The whole tree was copied without `Resources/`, `GhosttyKit.xcframework`
or the synced header; `setup-ghosttykit.sh` downloaded and verified the 131 MB artifact,
compiled the terminfo entry, and `xcodegen generate` then completed — the step that had
failed on all five CI runs since 2026-08-07. `diff -r` against the copy that shipped in
0.1.0 reports no difference.

One case is worth naming separately because it is the one that produced the bug. Running
setup on a tree that already has a verified GhosttyKit prints `already set up and verified`
and returns early — so the terminfo call sits *before* that return. Deleting
`Resources/terminfo` and re-running reproduces it exactly: the early return is taken, and
the directory is rebuilt anyway.

## Found while verifying, not fixed here

Two conditions still stand between this repository and a release anyone can install, both
outside this task's files:

- **No signing secrets exist on the remote.** `gh api repos/nguyenvanduocit/tenon/actions/secrets`
  returns `total_count: 0`, so `release.yml`'s identity import and notarization steps have
  nothing to read. A tag today would get past `xcodegen` and stop there instead.
- **The repository is private**, which T-114 already recorded as the reason no `brew
  install` has run: Homebrew fetches anonymously, and so does anyone following a release
  asset link.

## Owner / files (agent lock)

Session `b67a9a60` — released 2026-08-11 00:5x.
