# Troubleshooting

## The downloaded app will not open

**"A sealed resource is missing or invalid"** almost always means the archive was
extracted with `unzip`.

The archive stores extended attributes that Tenon's signature seals over.
Info-ZIP's `unzip` cannot restore them, so it writes them out as 735 stray `._*`
files inside the bundle, and Gatekeeper rejects the result. Delete what you
extracted and use Finder or `ditto`:

```sh
rm -rf Tenon.app
ditto -x -k Tenon-*-macos.zip .
spctl --assess -vv Tenon.app     # expect: accepted, source=Notarized Developer ID
```

## The app does not build

1. Re-run `./scripts/internal/setup-ghostty.sh` and confirm the pinned artifact
   passed its integrity check before extraction.
2. Run `.build/tools/xcodegen/bin/xcodegen generate`. `project.yml` is
   authoritative and the checked-in Xcode project must not drift from it.
3. Use the same `.build` paths as the documented commands, so SwiftPM and Xcode
   do not resolve two different package trees.
4. Run `swift build` first, to separate Swift compilation from signing, UI
   hosting and PTY failures.

::: warning Use the pinned XcodeGen, not one on your `PATH`
The version is a build input. 2.46.0 orders targets by declaration where 2.45.4
sorted them alphabetically, and it embeds a framework nothing loads dynamically.
Either difference makes a generated project disagree with the committed one on a
tree nobody edited — which broke CI for a day.
:::

## A plugin is discovered but does not run

Work down this list; it is ordered by how often each one is the answer.

1. **It is disabled.** A newly discovered plugin in a user inventory starts
   disabled. Enable it in Settings — after reading its manifest and source.
2. **The files are not where the host looks.** The directory needs a readable
   `manifest.json` and `main.js`, and the manifest ID must be unique.
3. **An intent is undeclared.** Every intent you send must be in `intents.uses`;
   every handler must be in `intents.provides` and bound exactly once during
   initial evaluation.
4. **Your edit never loaded.** A syntax, manifest, schema or binding error
   leaves the **last good generation running**. This is the trap: the plugin
   still works, so it looks like your change did nothing. Inspect the plugin
   error and the attributed logs.
5. **An event channel is undeclared.** A publisher declares the *local* channel
   name in `events.publishes`; an observer declares the *fully qualified* name
   in `events.observes`.

## An intent is denied or times out

```sh
tenon-cli intent list                     # can this caller even see it?
tenon-cli intent describe <intent-id>     # effects, audience, schema
```

- **It is not listed.** The audience does not include this caller. Naming an
  intent never grants authority, and a hidden contract answers "not found"
  rather than "not allowed".
- **A capability is missing.** Check the plugin manifest's permissions, the
  `network.allow` host list, and the workspace/pane scope.
- **It expired waiting for you.** Policy-confirmed operations need a live
  interactive confirmation. CLI and agent callers receive no standing consent,
  so an unattended one expires instead of silently escalating. That is
  fail-closed behaviour working, not a bug.
- **The deadline is too short — or you are misusing it.** A deadline covers
  admission, confirmation, provider execution and settlement. Raising it can
  diagnose slow work, but it must not be used to turn a stream into a held
  intent.

## A restored workspace looks incomplete

Restore is fail-soft on purpose:

- a workspace directory that no longer exists is dropped;
- an invalid tab is dropped;
- pane content that is unknown or unavailable becomes an empty pane.

Terminal panes restore their identity, layout, title and working-directory
placeholder, then launch a **fresh shell** when materialized. A process is never
serialized and resurrected.

If the catalog is corrupt, preserve a copy before moving it aside. **Do not
delete the whole Application Support tree** — plugin installation IDs,
enablement, private storage and consent records are independent state, and a
blanket delete throws all of it away to fix one file.

## Agent Lens says it is degraded

Agent Lens needs an authoritative session binding and refuses to guess.

For Codex, check that:

- the additive hook was installed in the **active** `CODEX_HOME`;
- the provider approved it;
- the transcript is a current-user regular JSONL file under
  `CODEX_HOME/sessions`.

A stale process, a child-agent fact, a mismatched process group, or a rotated
terminal-surface token is rejected.

While binding is unavailable, use **Terminal** mode — it is the exact evidence
path, and it is why the degradation is safe. Tenon deliberately will not pick
the newest transcript in a directory by modification time, because a supervision
tool showing you the wrong session confidently is worse than one saying it does
not know.

## `tenon-cli` says `unknown command`

Your installed app predates that verb. `rename`, for example, exists in the
source tree and not in every published build.

Every alias compiles to `intent send`, so the general form always works:

```sh
tenon-cli intent send workspace.pane.title.set.v1 --input '{"title":"…"}'
```

Check what your build actually has with `tenon-cli` on its own, and what version
it is with `tenon-cli ping`.

## `tenon-cli` cannot reach the app

`ping` failing means the socket is not there:

```sh
tenon-cli ping
echo "$TENON_SOCKET_PATH"
```

Outside a Tenon pane, `TENON_SOCKET_PATH` is unset and the CLI falls back to the
primary instance socket. Inside a pane it is exported for you. If you are
running a staging install, its socket is its own — `--staging` deliberately puts
that copy under a separate identity.
