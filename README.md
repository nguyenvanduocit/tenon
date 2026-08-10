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
- [`Sources/`](Sources/) — the native macOS app: `TenonIntentCore`, `TenonCore`,
  `TenonApp`, and `TenonCLI`.
- [`prototypes/spatial-layout/`](prototypes/spatial-layout/) — the structural
  design contract for component hierarchy, regions, and interactions.
- [`docs/README.md`](docs/README.md) — canonical documentation map, precedence,
  implementation status, guides, and research history.

## Install

Download the latest build from
[Releases](https://github.com/nguyenvanduocit/tenon/releases), open it in Finder, and
move `Tenon.app` to `/Applications`. It is universal, requires macOS 14 or later, and
is signed with a Developer ID certificate, hardened, notarized, and stapled — so a
machine that has never seen Tenon verifies it offline, with no right-click-to-open
step. Check what you downloaded before running it:

```bash
shasum -a 256 Tenon-*-macos.zip        # compare against SHA256SUMS on the release
spctl --assess -vv /Applications/Tenon.app   # accepted / source=Notarized Developer ID
```

**Extract it in Finder or with `ditto`, not with `unzip`.** The archive stores the
extended attributes the app's signature seals; `ditto -x -k Tenon-*-macos.zip .`
restores them, and Finder does the same. Info-ZIP's `unzip` cannot, so it writes them
out as 735 stray `._*` files inside the bundle instead — and `spctl` then rejects the
app with *"a sealed resource is missing or invalid"*, which looks like a corrupt
download but is only a corrupt extraction.

Releases are marked pre-release while the product is pre-alpha and its interfaces
still change between builds.

To run the code you are working on instead:

```bash
./scripts/setup-ghosttykit.sh   # once per clone
./install.sh --launch           # build Release and install to /Applications
```

That install is signed ad-hoc, which is all a machine needs to run software it
just compiled itself. `./install-staging.sh` puts a second copy beside it under
its own identity, so a candidate build can be exercised without replacing the
one you are working in.

A Homebrew cask is generated with each release (`scripts/make-cask.sh`), and
`brew install --cask` starts working once the repository is reachable without
credentials — Homebrew fetches anonymously.

[`docs/releasing.md`](docs/releasing.md) covers signing, notarization, and the
Homebrew cask — including why the distributed build is hardened and the local
one deliberately is not.

## Build

Tenon requires macOS 14+, Xcode, and XcodeGen 2.45.4+. The native app builds
without a JavaScript toolchain.

```bash
./scripts/setup-ghosttykit.sh
xcodegen generate
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
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

See [`docs/development.md`](docs/development.md) for controls, tests, the plugin
runtime, and the libghostty packaging details.

The native shell, spatial workspace model, libghostty embedding, workspace
catalog persistence, built-in slot surfaces, governed intent/plugin runtime, CLI
adapter, command palette, automations, and host-internal Agent Lens session
projection are implemented. The repository has headless, hosted integration, and
black-box macOS UI test layers; command output, not a hard-coded count in this
README, is the verification receipt.

Production hardening remains open, most importantly a hard isolation boundary
for untrusted plugin JavaScript and recorded performance/reliability receipts.
The release pipeline is implemented and proved end to end by a real artifact:
universal build, Developer ID signature, Hardened Runtime, notarization,
stapling, packaging, and a derived Homebrew cask. Gatekeeper accepts the
extracted archive as `Notarized Developer ID`.
The cross-session Attention Inbox, evidence-linked context capsules, and
safe-fan-out measurements remain product experiments rather than shipped
runtime capabilities. See [`docs/README.md`](docs/README.md) for the exact
status and authority of each document.
