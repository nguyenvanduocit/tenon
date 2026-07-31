# T-045: Install CLI is a no-op in the packaged app
> `Settings ▸ CLI ▸ Install` copies a `tenon-cli` binary that only exists next to the dev
> build. Nothing puts one inside `Tenon.app`, so the button that installs the CLI cannot
> install it from the app a user actually runs.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)
session 247281cf — ACTIVE, claimed 03:57.

Files this task will change:
- `poc/Tenon.xcodeproj` (a copy-files build phase into `Contents/MacOS`) and/or
  `poc/Package.swift` + `install.sh` / `dev.sh`, depending on which build produces the `.app`
- `poc/Sources/TenonApp/CLICommandInstaller.swift` (only if resolution has to change)
- `poc/Tests/TenonAppStateTests/**` for whatever of this is assertable headlessly

## Provenance
T-009's remaining follow-up, recorded there as *"bundle a self-contained tenon-cli inside
Tenon.app so Install works from the packaged app (needs static-link/build-phase; dev
`swift run` flow already works via the sibling binary)"*.

## Correction — the premise this task was filed on was wrong

Filed after reading `CLICommandInstaller.swift` alone, claiming *"nothing ever writes a
binary there"*. **`install.sh` does**, and has all along:

```
step "Bundling standalone tenon-cli"
install -m 755 "$BUILT_CLI" "$BUILT_APP/Contents/MacOS/tenon-cli"
```

Verified on the installed copy, 2026-07-31:

- `/Applications/Tenon.app/Contents/MacOS/tenon-cli` exists, 9.0 MB, installed 2026-07-30.
- `otool -L` lists **only** `/usr/lib` and `/System/Library/Frameworks` — no `@rpath`, no
  path into the build tree or the checkout.
- Copied to an unrelated directory and run there, it prints its usage and exits 0. So it is
  relocatable in practice, not merely by inspection.

Ordering in `install.sh` is right too: the CLI is copied **before**
`codesign --force --deep`, so it is signed along with the bundle rather than left as an
unsigned executable the OS would refuse.

## The gap that is real

`poc/project.yml` declares **no** CLI target and **no** copy phase. Everything above is a
step in `install.sh`. An app produced any other way — `xcodebuild` directly, Xcode's
Product ▸ Archive, a future CI job — silently ships without the CLI, and
`Settings ▸ CLI ▸ Install` degrades to *"No tenon-cli binary is available in this build to
install."* (`SettingsView.swift:172`). The behaviour is honest; the packaging is
forgettable.

**And it must not be closed the obvious way.** Adding a `tenon-cli` target to `project.yml`
would link the *dynamic* `TenonCore.framework` that the app embeds in `Contents/Frameworks`.
Inside the bundle that resolves; the moment `CLICommandInstaller` copies the binary to
`~/.local/bin` the framework is gone and the CLI is broken. SwiftPM builds it statically,
which is exactly why `install.sh` builds it separately — that separation is the design, not
an oversight.

## Criteria
- [x] The `.app` carries a `tenon-cli` in `Contents/MacOS` — it already did; `install.sh`
      builds it with SwiftPM and copies it in **before** `codesign --deep`, so it ships
      signed rather than as an unsigned executable the OS would refuse
- [x] The bundled binary is self-contained and relocatable — `otool -L` on the shipped file
      lists only `/usr/lib` and `/System/Library/Frameworks`; copied to an unrelated
      directory it prints its usage and exits 0, so this is behaviour, not inspection
- [x] `canInstall` resolves in a packaged run — `Bundle.main.url(forAuxiliaryExecutable:)`
      searches `Contents/MacOS`, and an executable `tenon-cli` is there.
      **The button click itself is human-verify-only** and is now item 13 of
      `.kanban/reports/human-verification-checklist.md`
- [x] The dev path is unchanged — `CLICommandInstaller.swift` is untouched, so `swift run
      tenon` still falls through to the sibling binary and the two branches keep their order
- [x] The packaging step can no longer fail silently — `install.sh` now **verifies the
      artifact that ships**, after `ditto` and after signing: the file exists, is
      executable, and links nothing outside the OS. ⚠️ **Scope stated honestly:** this
      closes the path that produces releases. A bare `xcodebuild`/Product ▸ Archive still
      yields an app with no CLI, degrading to *"No tenon-cli binary is available in this
      build to install."* Closing that too means teaching Xcode to run the SwiftPM build,
      and the reason it is not a plain Xcode target is now recorded in `project.yml` so the
      next person does not close it the way that breaks relocatability
- [x] `swift build` exit 0 + full `swift test` **838 / 0** — unchanged, as expected: no
      Swift source was touched

## Falsifying the new check

A verification that cannot fail is decoration, so it was tested against a binary that
*should* be rejected — the app's own `Tenon`, which links three embedded frameworks:

| File | Verdict |
|---|---|
| `Contents/MacOS/tenon-cli` | accept — self-contained |
| `Contents/MacOS/Tenon` | **reject** — 3 links to `@rpath/*.framework` |
| a missing path | **reject** — missing or not executable |

🐞 **The first version of the check silently accepted the broken binary.** It used
`grep -qvE`, and on BSD grep that reports no match here while plain `grep -vE` prints three
lines — so the shipped-artifact check would have waved through exactly what it exists to
catch. It now tests the captured output instead of grep's exit status. That the check was
falsified before being trusted is the only reason this was found.
