# PRD — Packaged CLI and per-channel local control

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-007` |
| Lifecycle | `shipped` |
| Owner | cli-control and intent-bus domains |
| Reviewers | product, security, app lifecycle, intent architecture, operations, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-009, T-045, T-050, T-051 |
| Existing design | [`design-cli.md`](../design-cli.md) |
| Acceptance specification | [`cli-control.feature`](cli-control.feature) |

## 1. Executive summary

### Problem

Humans and local agents need to discover and invoke Tenon operations without duplicating
workspace, terminal, file, or plugin semantics in a command server. They also need to target
the production or staging instance that owns their pane, survive stale socket artifacts, and
receive structured, bounded answers rather than hangs or misleading silence.

The historical design still labels the wire as v2. Current source and tests speak strict
protocol v3. Earlier task narratives also confused stale socket reclamation with the real
failure: the app already reclaimed dead socket nodes, but degraded startup once lacked useful
diagnostics. This PRD uses current source as the canonical contract.

### Proposed outcome

Tenon packages a relocatable `tenon-cli`. Each installed channel owns one secure Unix socket
and singleton claim. The wire has only `ping`, `app.focus`, intent discovery, and canonical
`intent.send`; friendly commands compile client-side to intents. Requests use bounded
newline-delimited `IntentValue` JSON, policy-filtered CLI discovery, structured failures,
explicit scope, finite deadlines, concurrency backpressure, and exactly-once settlement.

### Why now

The documentation migration must preserve the hard-won fixes from T-050/T-051 and prevent
future convenience work from reopening a domain-specific CLI API, silently falling across
channels, or downgrading the live v3 wire to stale prose.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| CLI client/parser | [`Sources/TenonCLI`](../../Sources/TenonCLI) | high | commands, scope precedence, output and exit behavior |
| wire/actions | [`CLIProtocol.swift`](../../Sources/TenonIntentCore/CLIProtocol.swift), [`CLIAction.swift`](../../Sources/TenonIntentCore/CLIAction.swift) | high | v3 framing, bounds, five closed actions |
| server/singleton | [`CLISocketServer.swift`](../../Sources/TenonApp/CLISocketServer.swift), [`AppInstanceChannel.swift`](../../Sources/TenonApp/AppInstanceChannel.swift) | high | secure paths, locks, recovery, backpressure |
| adapter | [`CLICommandExecutor.swift`](../../Sources/TenonApp/CLICommandExecutor.swift) | high | control-plane versus canonical dispatcher |
| packaging | [`CLICommandInstaller.swift`](../../Sources/TenonApp/CLICommandInstaller.swift), `install.sh` | high | production-only global install and relocatable bundle artifact |
| task/design archive | T-009/T-045/T-050/T-051, `design-cli.md` | medium | intent and historical receipts; v2 text is stale |

### Context questions and assumptions

| Question | Answer |
|---|---|
| Core problem? | Safe local discovery and control of the exact running Tenon channel through canonical product contracts. |
| Primary users? | local human shell users, coding agents, scripts, and second app launches |
| Success? | one bounded request/response, correct target, no duplicated domain API, no indefinite wait |
| Fixed constraints? | same-user local trust, closed channels/actions, Intent Bus policy, secure filesystem nodes |
| Unknown? | production release artifact continues to require the guarded `install.sh` path rather than bare Xcode Archive |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `CLI-A-001` | Same-macOS-user authority is the intended local trust boundary. | threat-model review | accepted |
| `CLI-A-002` | Eight concurrent connections fit local agent workloads. | saturation telemetry/reproduction | asserted bound; revisit by evidence |
| `CLI-A-003` | The release path remains `install.sh`. | release checklist | current operational constraint |

## 3. Users, jobs, and vocabulary

The primary user is a local operator or supervised agent running inside or outside a Tenon
terminal. They need to inspect state, target copied UUIDs, write/read/wait on terminals, and
invoke plugin-owned contracts while observing the same validation and policy as every caller.

- Discover only operations the CLI principal may call.
- Target the owning pane automatically or an exact copied workspace/tab/pane ID explicitly.
- Distinguish “app not reachable,” control rejection, and canonical intent failure.
- Start production and staging side by side while keeping one instance per channel.
- Install a self-contained command without administrator privileges.

| Term | Meaning | Not to be confused with |
|---|---|---|
| channel | closed installed identity: production or staging | caller principal/wire field |
| control action | transport/lifecycle operation | product domain command |
| convenience alias | client-side constructor for `intent.send` | new wire action |
| scope | workspace/tab/pane designation | authorization grant |
| claim | stable locked `tenon.lock` inode | socket node itself |

## 4. Goals and success measures

- `CLI-G-001` — One public CLI adapter reaches canonical intents without semantic forks.
- `CLI-G-002` — Channel discovery, singleton activation, and stale recovery fail safely.
- `CLI-G-003` — Every payload, wait, connection, deadline, and settlement is bounded.
- `CLI-G-004` — Packaging works from the supported installed release and dev paths.

| ID | Metric | Target | Evidence |
|---|---|---|---|
| `CLI-M-001` | domain-specific wire actions | zero | action fitness test |
| `CLI-M-002` | same-channel simultaneous primaries | zero | socket integration tests |
| `CLI-M-003` | consent waits outliving deadline | zero | dispatcher deadline tests |
| `CLI-M-004` | accepted connections above bound | zero above 8 | server saturation tests |
| `CLI-M-005` | staging request silently routed to production | zero | channel/env tests |

| Guardrail | Bound |
|---|---|
| protocol | exact v3; one request and response per connection |
| encoded value | IntentValue hard encoded/depth/count/string/key limits |
| correlation/action | nonempty, at most 128 UTF-8 bytes |
| timeout | 1…60,000 ms; wait condition at most 55,000 ms plus 1,000 ms transport margin |
| idempotency key | at most 512 UTF-8 bytes |
| connections | 8 live, 250 ms admission grace, 120 s server watchdog |

## 5. Scope

### In scope

- packaged/self-contained CLI and Settings installer;
- production/staging identity, secure socket/claim, singleton focus, stale recovery;
- v3 request/response framing, parser, errors, discovery and send;
- convenience aliases for state, send, read, wait, pane focus, and tab focus;
- scope/env precedence, deadline/consent behavior, backpressure and teardown.

### Non-goals

- remote/network control, cross-user authentication, or generic app principal;
- domain handlers in the socket server;
- unbounded terminal history in viewport read;
- disconnect-driven cancellation (deadlines bound abandoned work; earlier cancellation is a
  possible follow-up);
- promising that a bare Xcode Archive includes the SwiftPM-static CLI.

## 6. User experience

`tenon-cli intent list|describe|send` is the canonical interface. `state`, `send`, `read`,
`wait`, `pane-focus`, and `tab-focus` are aliases. Success prints pretty, sorted JSON and
exits 0; intent/control failure prints structured JSON and exits 1; usage errors explain the
problem on stderr and exit 2.

A neutral shell defaults to production. A Tenon pane receives `TENON_SOCKET_PATH` and
`TENON_PANE_ID`, so it targets its owner. Explicit `--pane` beats the environment; explicit
`--tab` suppresses inherited pane scope. `--workspace`, `--tab`, and `--pane` designate but
do not authorize. A second same-channel app launch focuses the primary and exits before
assembling another workspace; the other channel may continue independently.

Invalid nodes, ownership/mode failures, malformed frames, unknown fields/actions, and busy
capacity fail closed. A primary that cannot safely claim its channel is unavailable; a bind
degradation that still permits the app to run is logged with its exact reason, while child
panes keep that channel's intended path rather than falling back.

## 7. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `CLI-FR-001` | The product **MUST** package a self-contained `tenon-cli` and production Settings **MUST** install it to `~/.local/bin/tenon-cli` as executable. | shipped | `@req-cli-fr-001` |
| `CLI-FR-002` | Staging **MUST NOT** replace the global command; its panes **MUST** use their bundled CLI and staging socket environment. | shipped | `@req-cli-fr-002` |
| `CLI-FR-003` | Production and staging **MUST** use distinct bundle identity, Application Support root, socket directory, and singleton claim. | shipped | `@req-cli-fr-003` |
| `CLI-FR-004` | A neutral client **MUST** target production unless `TENON_SOCKET_PATH` explicitly names another channel. | shipped | `@req-cli-fr-004` |
| `CLI-FR-005` | Every terminal **MUST** receive its owning `TENON_SOCKET_PATH`, `TENON_PANE_ID`, and channel-local agent hook path. | shipped | `@req-cli-fr-005` |
| `CLI-FR-006` | The server **MUST** create/verify a real same-user `0700` socket directory and a `0600` socket node without following symlinks. | shipped | `@req-cli-fr-006` |
| `CLI-FR-007` | The stable claim **MUST** be a same-user, single-link, regular `0600` file opened no-follow/CLOEXEC and locked nonblocking until socket removal. | shipped | `@req-cli-fr-007` |
| `CLI-FR-008` | A same-channel secondary **MUST** send `app.focus`, exit before durable workspace construction, and **MUST NOT** steal the primary's socket. | shipped | `@req-cli-fr-008` |
| `CLI-FR-009` | Only the claim owner **MAY** remove an unresponsive stale socket node; regular files and symlinks **MUST** remain untouched. | shipped | `@req-cli-fr-009` |
| `CLI-FR-010` | Unsafe claims **MUST** stop app startup; recoverable bind degradation **MUST** be logged and retain the channel-local client path. | shipped | `@req-cli-fr-010` |
| `CLI-FR-011` | The wire **MUST** speak exact protocol v3 as one bounded newline-delimited JSON request and response per connection. | shipped | `@req-cli-fr-011` |
| `CLI-FR-012` | Requests **MUST** accept only `v`, `id`, `action`, and object `params`; unknown/malformed/oversize input **MUST** return a closed control error. | shipped | `@req-cli-fr-012` |
| `CLI-FR-013` | The action set **MUST** be exactly `ping`, `app.focus`, `intent.list`, `intent.describe`, and `intent.send`. | shipped | `@req-cli-fr-013` |
| `CLI-FR-014` | `ping` **MUST** report protocol version, process ID, and active state without claiming provider readiness. | shipped | `@req-cli-fr-014` |
| `CLI-FR-015` | `app.focus` **MUST** activate the existing app and bring its primary window forward. | shipped | `@req-cli-fr-015` |
| `CLI-FR-016` | `intent.list` and `intent.describe` **MUST** expose only policy-filtered contracts callable by the CLI principal; hidden names **MUST** appear not found. | shipped | `@req-cli-fr-016` |
| `CLI-FR-017` | `intent.send` **MUST** use the production dispatcher with canonical input, scope, target, idempotency, timeout, policy, provider selection, validation, and telemetry. | shipped | `@req-cli-fr-017` |
| `CLI-FR-018` | Intent failures **MUST** preserve canonical source, code, details, retry guidance, outcome, request ID, and provider ID. | shipped | `@req-cli-fr-018` |
| `CLI-FR-019` | Friendly domain commands **MUST** compile to `intent.send` client-side and **MUST NOT** add server actions or duplicate services. | shipped | `@req-cli-fr-019` |
| `CLI-FR-020` | Scope **MUST** validate UUIDs, reject caller-supplied `userGestureID`, and remain an authorization-neutral designation. | shipped | `@req-cli-fr-020` |
| `CLI-FR-021` | Pane scope precedence **MUST** be explicit `--pane`, then `TENON_PANE_ID`, except an explicit `--tab` suppresses the inherited pane. | shipped | `@req-cli-fr-021` |
| `CLI-FR-022` | `wait` **MUST** support `exit`, `tui-idle`, and `command-finished`, settle once with `met`, and allocate a timeout margin for the transport. | shipped | `@req-cli-fr-022` |
| `CLI-FR-023` | Caller/default deadlines **MUST** bound confirmation and dispatch; CLI/agent `.policy` calls **MUST NOT** acquire standing consent. | shipped | `@req-cli-fr-023` |
| `CLI-FR-024` | The server **MUST** cap live connections, answer excess load as busy, watchdog an unreturned handler, and settle/close/release each permit exactly once. | shipped | `@req-cli-fr-024` |
| `CLI-FR-025` | Server teardown **MUST** settle pending clients as unavailable and release socket and claim ownership in safe order. | shipped | `@req-cli-fr-025` |
| `CLI-FR-026` | Success/failure/usage **MUST** use exit codes 0/1/2 respectively and machine-readable JSON for server replies. | shipped | `@req-cli-fr-026` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `CLI-NFR-001` | security | Socket, claim, ownership, type, mode, symlink, and CLOEXEC rules **MUST** fail closed. | shipped | `@req-cli-nfr-001` |
| `CLI-NFR-002` | boundedness | Payload/value/action/id/scope/key/timeout/connection/request lifetime bounds above **MUST** be enforced incrementally where applicable. | shipped | `@req-cli-nfr-002` |
| `CLI-NFR-003` | responsiveness | Accept/read/decode **MUST** run off MainActor; UI hops **MUST** be minimal; a slow provider **MUST NOT** block accept or unrelated lanes. | shipped | `@req-cli-nfr-003` |
| `CLI-NFR-004` | architecture | CLI domain work **MUST** cross Intent Bus; only ping and app focus are direct lifecycle control. | shipped | `@req-cli-nfr-004` |
| `CLI-NFR-005` | compatibility | Production legacy socket path and neutral-shell behavior **MUST** remain compatible; protocol versions **MUST** reject rather than guess. | shipped | `@req-cli-nfr-005` |
| `CLI-NFR-006` | packaging | Release verification **MUST** prove bundled CLI exists, is executable, signed in bundle order, and links only OS libraries/frameworks. | shipped for `install.sh` | `@req-cli-nfr-006` |
| `CLI-NFR-009` | packaging | Installing **MUST** be possible from a terminal inside the app being replaced: the installer **MUST** detect that case from its own process ancestry, run the replacement outside the caller's terminal session so the app's own job teardown cannot reach it, wait for the old app to exit before deleting its bundle, and reopen the app afterwards. Both paths **MUST** use one replacement implementation, and it **MUST** keep the `CLI-NFR-006` verification order. | shipped | `@req-cli-nfr-009` |
| `CLI-NFR-007` | observability | Control degradation and structured failures **MUST** identify actionable cause without exposing secrets. | shipped | `@req-cli-nfr-007` |
| `CLI-NFR-008` | lifecycle | Disconnect need not cancel dispatch early, but every abandoned request **MUST** terminate by its deadline/watchdog. | shipped | `@req-cli-nfr-008` |

## 8. Acceptance specification

[`cli-control.feature`](cli-control.feature) tags all 34 requirements. Pure codec/parser,
socket integration, dispatcher, packaging checks, channel state, and installed Settings
verification are the evidence seams. The bare-Xcode-Archive limitation remains an explicit
operational exclusion rather than an unverified promise.

## 9. Product and architecture constraints

| Interaction | Classification | Reason |
|---|---|---|
| singleton ping/focus | CONTROL PLANE | exact mechanism/app lifecycle |
| intent discovery | CONTROL PLANE | policy-filtered protocol discovery |
| domain invocation | INTENT | finite request/reply across CLI principal boundary |
| executor to application service | DIRECT | provider adapter reaches the same semantic owner |
| terminal wait observer | internal RESOURCE | caller receives one finite result; observer ends with request |

The server owns descriptors and permits; the intent runtime owns dispatch. The CLI principal
is host-minted and has the `cli` audience. Same-user socket access is explicit local trust,
but capability/policy still gates every intent and scope does not grant authority. Host-native
Settings follows `docs/designs.md`; command output is stable machine-readable JSON.

## 10. Delivery and implementation matrix

| Requirements | Source/evidence | State/gap |
|---|---|---|
| 001…005 | installer, `install.sh`, channel/env composition | shipped; bare Archive excluded |
| 006…010 | `AppInstanceChannel`, `CLISocketServer`, socket tests | shipped |
| 011…013/018/020/026 | v3 codec/action parser/client tests | shipped |
| 014…019 | `CLICommandExecutor`, intent boundary tests | shipped |
| 021…023 | CLI builder, terminal provider, consent deadline tests | shipped |
| 024…025 | connection permits/watchdog/drain tests | shipped |
| NFR set | fitness, saturation, packaging, installed checklist | shipped under stated release path |

Any future alias lands only in the client. A new domain capability first lands as a reviewed
intent contract. Protocol v4 requires exact migration/rejection tests; current v2 wording in
`design-cli.md` is superseded by this PRD and live v3 source.

## 11. Risks and mitigations

| ID | Risk | Mitigation |
|---|---|---|
| `CLI-R-001` | convenience command becomes a sixth wire action | closed parser and source fitness test |
| `CLI-R-002` | staging degradation falls back to production | always inject intended channel path |
| `CLI-R-003` | stale cleanup steals a live socket | claim owner + live probe + node-type check |
| `CLI-R-004` | consent or disconnected request lives forever | dispatcher deadline plus server watchdog |
| `CLI-R-005` | packaged CLI breaks after copy | static SwiftPM build and dependency verification |

## 12. Open questions and decisions

| Date | Decision | Rationale | Supersedes |
|---|---|---|---|
| 2026-07-31 | CLI/agent policy calls remain interactive-only. | socket access is not installation consent | standing CLI consent |
| 2026-07-31 | Disconnect cancellation is optional optimization; deadline is correctness bound. | avoids unbounded work without premature kqueue design | original T-050 checkbox |
| 2026-08-06 | Only ping and app focus directly control the app; domain work is intents. | interaction boundary law | old domain CLI verbs |
| 2026-08-09 | Current wire is v3. | `CLIProtocol.version == 3` and current tests | `design-cli.md` wire-v2 text |
| 2026-08-10 | The installer detaches its replacement half when run from inside the app it replaces, rather than refusing. | the only terminal a person working on Tenon has open is a Tenon pane, and refusing would send them to another app to install this one. Detaching is not a preference: `TerminalJobTerminator.sweep` lists victims with `ps -t <tty>` and escalates to SIGKILL, so leaving the terminal session is the one thing that survives — measured, a `nohup` child is still listed and dies, a `setsid` child is not listed and completes | installing only from outside the app |

Open operational question: if Xcode Archive becomes a supported release path, it must gain an
equivalent self-contained SwiftPM CLI build/copy/verification step rather than a dynamic target.

## 13. Verification receipts

| Date | Worktree | Scope | Result | Exclusions |
|---|---|---|---|---|
| 2026-08-09 | current dirty tree, docs audit | current CLI/channel/socket/parser/executor/installer source and task receipts | canonical v3 behavior mapped | no live socket or installed button run in this pass |
| 2026-08-10 | current tree, T-113 | `CLI-NFR-009` self-install: ancestry detection, detached survival, and the whole replace path | detection returned self-install for `/Applications/Tenon.app` and ordinary for two other bundles, run from a real Tenon pane; in a `forkpty` PTY, a `nohup` child was listed by `ps -t <tty>` and killed by a simulated sweep while a `setsid` child was absent from the list and ran to completion; a foreground staging install went build → quit → wait → replace → sign → verify → `exit=0`; a forced-branch copy of the installer, differing from the real one by the single `if` line, handed off to the detached installer, which quit staging, waited, replaced, signed, verified, and reopened it after its caller had exited | the detached path was proved against `Tenon Staging.app`, not against `Tenon.app` — a real self-install kills the session doing the verifying, so the one thing not directly observed is a live Tenon replacing itself |
| 2026-08-10 | current tree, T-115 | the app/CLI instance channel after the bundle identifier moved from `com.firegroup.tenon` to `dev.tenon.app` | the control socket path and single-instance channel are derived from the bundle identifier, so both ends moved together: `CLISocketServerTests` resolved the closed channels for the new production and staging identifiers, and `InteractionBoundaryFitnessTests` confirmed the installer scripts and `AppInstanceChannel` agree on the same pair. Both suites were **red first** against the old identifier, which is how the rename found every file that carried it. Full suite 1872 / 0 | the identifier is proved consistent in-tree, not on disk: no install replaced the running app in this session, so a live socket handshake under the new identifier is unobserved, and any `/Applications` bundle still carrying the old identifier remains launchable by it |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD | consolidate shipped CLI and correct v2/stale-socket history |
