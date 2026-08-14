# Tenon documentation site

The public documentation at
[tenon-docs.pages.dev](https://tenon-docs.pages.dev). VitePress 1.6.4, built
with Bun, deployed to Cloudflare Pages.

Set `SITE_URL` at build time when a custom domain lands — it is what the
sitemap names, and a sitemap pointing at a host nobody serves is worse than
none.

```sh
bun install
bun run dev        # http://localhost:5173
bun run build      # → .vitepress/dist
bun run preview    # serve the built output
```

## What is written and what is generated

Prose is hand-written for people using Tenon. `docs/` in the repository root is
the *engineering* record — PRDs, design decisions, precedence rules — and stays
that way; this site cites it where a reader needs the full contract.

Two things are generated and **must not be edited by hand**:

| Output | Generator | Source |
|---|---|---|
| `reference/intents/**` + `.vitepress/generated/intent-sidebar.json` | `scripts/gen-intents.mjs` | `CoreIntentCatalog.swift` + a running Tenon |
| `.vitepress/generated/cli-usage.txt` | `scripts/gen-cli.mjs` | `Sources/TenonCLI/main.swift` |

```sh
bun run gen        # both
bun run gen:intents
bun run gen:cli
```

Their output is committed, so the site builds on a machine with no Tenon, no
Swift and no toolchain beyond Bun — which is what lets Cloudflare Pages build it
from a plain clone.

### Why `gen:intents` reads two sources

`tenon-cli intent list` is the authoritative answer for anything the CLI
principal may call, schemas included. It is also **fail-closed**: contracts
whose audience is `{plugin}` answer `intent_not_found` to a shell, exactly as a
name that does not exist does. A CLI-only generator would therefore publish a
silently partial inventory — 37 of 51 at the time of writing.

So the Swift catalog decides *which* contracts exist, and the CLI fills in what
their schemas are. Where the CLI cannot see one, the page says so and points at
`tenon.intents.list()` rather than printing a hand-copy that will go stale. The
index records which build the schemas came from.

Run it against a **current** Tenon. If the app is older than the catalog beside
it, the generator says which contracts are affected and the index carries a
warning — that is working as intended, not a reason to hand-edit the output.

## Checking a change

`bun run build` fails on a dead link (`ignoreDeadLinks: false`), which catches
most breakage. It does not catch layout.

```sh
bun run build && bun run preview --port 4173 &

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir=/tmp/shot-profile about:blank &

bun scripts/shoot.mjs /tmp/shots dark  390x844   /reference/intents/ /reference/cli
bun scripts/shoot.mjs /tmp/shots light 1440x1100 / /guide/install
```

`shoot.mjs` emulates the colour scheme and viewport, then **measures** horizontal
overflow and console errors rather than leaving them to be spotted in a picture
— a screenshot is cropped to the viewport, so a table overflowing off the right
edge is exactly the defect a screenshot cannot show you.

## Deploying

Cloudflare Pages, building from this directory:

| Setting | Value |
|---|---|
| Root directory | `website` |
| Build command | `bun run build` |
| Output directory | `.vitepress/dist` |

Or push a build directly:

```sh
bun run build
wrangler pages deploy .vitepress/dist --project-name tenon-docs
```

## Conventions

- **Cite the tree, not memory.** Every example here was checked against source
  or a running app. `workspace.pane.split.v1` takes `axis`, not `orientation`;
  `process.exec.v1` returns `standardOutput.text`, not `stdout`. Both were wrong
  in a first draft.
- **Say what is not built.** The Attention Inbox and context capsules are
  product targets, and the pages that mention them say so.
- **Name the limit.** Plugin isolation is not a process sandbox; the docs state
  that wherever enabling a plugin comes up, rather than once in a footnote.
