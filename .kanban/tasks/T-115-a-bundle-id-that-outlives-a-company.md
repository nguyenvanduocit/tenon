# T-115: A bundle id that outlives a company
> `com.firegroup.tenon` ties the product's macOS identity to one legal entity. Move it to
> the `dev.tenon` namespace the plugins already use, before the first release makes the
> identity expensive to change.

- **priority**: high
- **effort**: S
- **prd**: TENON-PRD-015 (release identity), TENON-PRD-007 (CLI/socket channel identity)
- **was blocked on**: T-113, which owned `install.sh` and `scripts/install-replace.sh`;
  it finished and released both mid-task, so this landed in the same session

## Why now and not later

macOS keys TCC consent, Keychain ACLs, LaunchServices registration, preferences, and saved
state to the bundle identifier. Changing it after people have installed Tenon resets all of
them for every user. Changing it before the first release costs nothing — which makes the
window for this decision exactly now.

The product decision behind it (owner: 2026-08-10): Tenon's identity should not be the
company's. `com.firegroup.tenon` reads as an internal tool of one organisation, and if the
product ever moves — open source, a different entity, a personal project — the identifier
moves with the company rather than with the product. The plugins already publish under
`dev.tenon.*` (`dev.tenon.kanban`, `dev.tenon.clock`), so the host is the odd one out.

Note this is independent of the *signing* identity: the Developer ID certificate can stay
`GOLDEN CLOUD TECHNOLOGY COMPANY LIMITED (694MCRBCD6)` while the bundle id becomes
`dev.tenon.app`. Team ID and bundle id are separate decisions, and only the second is
cheap to change later — the first resets TCC and Keychain the same way.

## Proposed identifiers

| Now | After |
|---|---|
| `com.firegroup.tenon` | `dev.tenon.app` |
| `com.firegroup.tenon.staging` | `dev.tenon.app.staging` |
| `com.firegroup.tenon.core` / `.intent-core` / `.*-tests` | `dev.tenon.core` / `.intent-core` / `.*-tests` |

## Files (11, measured with `rg -l 'com\.firegroup'`)

Free to change:

- `project.yml` (8) and the regenerated `Tenon.xcodeproj/project.pbxproj` (16)
- `Sources/TenonApp/DiagnosticsRuntime.swift` (4), `TenonLog.swift` (2),
  `AppInstanceChannel.swift` (2)
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` (3),
  `Tests/TenonAppStateTests/CLISocketServerTests.swift` (2)
- `install-staging.sh` (1), `docs/prds/diagnostics-and-resource-monitor.feature` (1)

Were held by T-113, released mid-session and changed here:

- `install.sh` (4), including the `case` that accepted only `com.firegroup.tenon` and
  `com.firegroup.tenon.staging` as install identifiers
- `scripts/install-replace.sh` (1)

## Criteria

- [x] No `com.firegroup` remains anywhere outside git history: `rg 'com\.firegroup'` is empty
- [x] `install.sh`'s identifier allowlist accepts the new pair and nothing else
- [x] The CLI control socket path and single-instance channel still agree between app and
      CLI after the rename (`CLISocketServerTests`, `AppInstanceChannel`)
- [x] A staging install and a normal install can still both be present at once
- [x] `make-cask.sh`'s `zap` paths follow the new identifier — it derives them from the
      artifact, so this should need no edit, and that is worth confirming rather than assuming
- [ ] One install on this machine, verified: app launches, CLI connects, old
      `com.firegroup.tenon` bundle removed from `/Applications` so LaunchServices stops
      offering two identities
- [x] PRD-015 records the decision; PRD-007 records the socket/channel identity change

## Evidence

TDD ran in the right order by accident of where the identifier was pinned: rewriting the
two test files first turned five assertions red, and those assertions **named every
remaining file** — `AppInstanceChannel.swift`, `install.sh`, `install-staging.sh` — so the
fitness tests doubled as the work list. Full suite **1872 / 0** afterwards, and
`rg 'com\.firegroup'` is empty across the tree.

A staging install proved the new identity end to end while this session stayed alive.
`Tenon Staging.app` reinstalled as `dev.tenon.app.staging`, launched, and answered on its
own channel: `ping` returned **pid 61165** against production's 37334, over
`/tmp/tenon-staging-501/tenon.sock` created at install time, with its own
`~/Library/Application Support/Tenon Staging`. Through that socket it listed **34 intents**
and returned live workspace state. Both channels ran side by side throughout.

One measurement corrected a wrong reading along the way: `tenon-cli ping` run from the
staging bundle answered with production's pid. That is not a defect —
`CLIClient.socketPath()` (`Sources/TenonCLI/CLIClient.swift:26-31`) always resolves the
production path unless `TENON_SOCKET_PATH` is set, which is what `AppInstanceChannel:20-21`
means by production keeping every legacy path. The CLI shipped *inside* a staging bundle
still talks to production by default, and that is worth knowing before someone debugs it
as a bug.

**Still open, and it needs the production install:** `/Applications/Tenon.app` remains
`com.firegroup.tenon`. Until it is replaced, `open -b com.firegroup.tenon` still resolves
and anything holding the old identifier can launch it.

## Owner / files (agent lock)

Session `407fc72f` — released 2026-08-10 22:1x.
