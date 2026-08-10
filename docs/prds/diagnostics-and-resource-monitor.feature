# language: en

@prd-TENON_PRD_016
Feature: Retain local health evidence and inspect live process resources honestly
  People diagnosing Tenon need bounded evidence after a stall and truthful ownership while it runs.
  PRD: diagnostics-and-resource-monitor.prd.md

  Rule: The watchdog notices a main-runloop stall from outside the stalled queue

    @req-drm-fr-001 @launch
    Scenario: Diagnostics arms once when the app becomes ready
      Given Tenon has resolved its channel-specific application-support paths
      When app readiness starts diagnostics
      Then one launch record names the run, PID, version, build, channel, observer, and watchdog
      And orderly shutdown attempts one termination for that same run within 250 milliseconds
      And a durable termination proves a clean close
      But a run without it means unclean exit or unavailable persistence, not crash proof alone

    @req-drm-fr-002 @observer
    Scenario: A framework observer that never returns cannot be hidden by the health beat
      Given the health observer watches all relevant main-runloop activities at maximum order
      When an earlier observer prevents the runloop phase from completing
      Then the health observer cannot report a later beat
      And the watchdog can observe the silence

    @req-drm-fr-003 @req-drm-nfr-001 @off-main
    Scenario: The watchdog still fires while the main thread spins
      Given the main thread is held in a busy loop
      When the one-second watchdog deadline arrives
      Then the private diagnostics queue probes health
      And a main-queue stall cannot prevent the evidence write

    @req-drm-fr-003 @responsiveness
    Scenario: Queue saturation cannot hide behind fresh runloop phase beats
      Given runloop phase beats continue while one main-queue ping remains pending
      When that one ping exceeds the stall threshold
      Then one responsiveness-stall incident is recorded
      And no additional ping is enqueued until the pending ping returns

    @req-drm-fr-004 @threshold
    Scenario Outline: Stall time begins at the last completed turn
      Given the last runloop beat occurred at second 10
      When a probe occurs at second <probe>
      Then <outcome>

      Examples:
        | probe | outcome |
        | 14.9 | no stall is reported |
        | 16 | one stall reports 6 seconds of silence |
        | 100 | recovery at 110 later reports a 100-second episode |

    @req-drm-fr-005 @escalation
    Scenario: A long stall writes an interval trail instead of a heartbeat flood
      Given a stall was first reported at second 6
      When the watchdog probes every second for another hour
      Then continued-stall records occur only after each 60-second escalation interval
      And every intermediate probe is silent

    @req-drm-fr-006 @recovery
    Scenario: The first completed turn closes one episode
      Given the runloop has been stalled since its last beat
      When it completes a turn again
      Then one recovered record contains the full stall duration
      And the next stall begins a distinct episode

    @req-drm-fr-007 @figures
    Scenario Outline: Health records carry the figures needed to reconstruct the incident
      Given diagnostics emits <kind>
      When the record is appended
      Then run ID, PID, version, build, channel, last phase, beat age, and beat sequence are present
      And footprintMB and interval CPU core percent are measured or explicitly unavailable
      And <timing>

      Examples:
        | kind | timing |
        | launch | no seconds field is required |
        | stall | seconds contains the measured silence |
        | stall-continues | seconds contains the elapsed episode |
        | recovered | seconds contains the full episode duration |

    @req-drm-fr-008 @req-drm-fr-009 @stack-sample
    Scenario Outline: Stack capture follows incident episodes rather than probe count
      Given the runloop is in <episode state>
      When <event>
      Then <sample outcome>

      Examples:
        | episode state | event | sample outcome |
        | its first stall | the threshold is crossed | one separate-queue three-second sample streams through a bounded private pipe for that unique run/incident |
        | the same continuing stall | later escalation probes fire | no additional sample starts |
        | a recovered app | a second stall begins | one new sample starts without replacing the first incident |

    @req-drm-fr-008 @truthful-sample
    Scenario: A sample receipt distinguishes attempt from durable evidence
      Given one incident has scheduled a sample into its bounded private capture
      When the sampler exits
      Then only exit zero plus privacy filtering and a non-empty atomic commit produces stall-sample-completed
      And launch, timeout, nonzero, empty, or commit failure produces stall-sample-failed

    @req-drm-fr-010 @silent-healthy
    Scenario Outline: Normal operation creates no incident noise
      Given <condition>
      When health is probed
      Then no journal or stack-sample record is created

      Examples:
        | condition |
        | the runloop keeps completing turns |
        | silence remains below five seconds |

  Rule: The local journal preserves the newest usable evidence without becoming an outage

    @req-drm-fr-011 @path
    Scenario: App health evidence has one channel-local application home
      Given an application-support root is resolved for the current channel
      When diagnostics constructs its paths
      Then the journal is diagnostics/health.jsonl under that root
      And each stack and transition prelude belongs to its own run/incident directory
      And only the newest eight incident directories remain

    @req-drm-fr-012 @jsonl
    Scenario: A killed process can damage at most its last write
      Given two complete diagnostic records were appended as separate JSON lines
      When the process leaves one truncated final line
      Then each complete line still decodes with ISO-8601 date, kind, message, and figures
      And the next append repairs the final boundary before writing a valid new line

    @req-drm-fr-013 @req-drm-nfr-002 @bounded-journal
    Scenario: Journal growth drops old evidence before current evidence
      Given 2,200 decodable records are appended
      When the journal enforces its 2,000-record ceiling
      Then exactly the newest 2,000 records remain in order
      And one record is at most 16 KiB, the journal at most 4 MiB, and a sample at most 64 MiB
      And more appends do not make the retained record set unbounded

    @req-drm-fr-014 @corruption
    Scenario: One malformed line cannot erase neighboring evidence
      Given a journal contains valid lines before and after malformed JSON or invalid UTF-8
      When records are read
      Then the malformed line is skipped
      And every decodable record is returned in original order

    @req-drm-fr-015 @fail-soft
    Scenario Outline: Diagnostics cannot terminate the session it observes
      Given <operation> fails
      When diagnostics handles the failure
      Then the user session continues
      And no false success evidence is invented
      And persistence retains at most 64 incident events while capture retains at most two jobs

      Examples:
        | operation |
        | directory creation or append |
        | journal trimming or reading |
        | physical-footprint lookup |
        | unified logging |
        | process stack sampling |

    @req-drm-fr-016 @export
    Scenario Outline: Export copies only after a person chooses a destination
      Given the local journal contains dated records and figures
      When the save panel is <choice>
      Then <outcome>

      Examples:
        | choice | outcome |
        | confirmed | readable ISO-8601 text contains record count, messages, sorted figures, and committed stack/transition artifacts at the chosen path |
        | cancelled | no export is written and the journal remains unchanged |

    @req-drm-fr-017 @logging
    Scenario: App-owned diagnostics are filterable without scattered NSLog calls
      Given diagnostics, terminal, or CLI emits an app health message
      When unified logging records it
      Then subsystem dev.tenon.app carries one of the bounded owned categories

    @req-drm-fr-018 @req-drm-nfr-008 @teardown
    Scenario: Stopping diagnostics ends both observation resources
      Given a probe timer and main-runloop observer are installed
      When diagnostics stops or deinitializes
      Then the timer is cancelled
      And the observer is removed
      And an orderly started run attempts one termination receipt within the bounded flush

    @req-drm-fr-019 @req-drm-nfr-003 @privacy
    Scenario Outline: Sensitive work never becomes diagnostic evidence
      Given a pane or process exposes <sensitive value>
      When journal, stack metadata, export, UI history, and structured logs are produced
      Then the sensitive value is absent
      And raw stack output is privacy-filtered before its artifact is committed

      Examples:
        | sensitive value |
        | terminal output or agent transcript |
        | pane title or working directory |
        | plugin identifier |
        | command line or environment |
        | file content or secret |

    @req-drm-fr-020 @local-only
    Scenario: No opt-in mistake can upload the health journal
      Given diagnostics is running normally
      When records and a stack sample are created
      Then they remain on the local machine
      And only a confirmed save action copies a readable export

  Rule: The planned Resource Monitor opens as host-owned, truthful native UI

    @req-drm-fr-021 @entry
    Scenario: Resources belongs to the shell rather than plugin contribution space
      Given the native shell title bar is visible
      When the monitor ships
      Then Resources appears in the shell's own chrome before the trailing host control
      And the plugin-only workspace status bar remains contribution-only

    @req-drm-fr-022 @trigger
    Scenario Outline: The compact trigger never disguises old data as current
      Given title-bar width is <width>
      When the trigger renders the latest snapshot
      Then <visual>
      And tooltip and accessibility value name CPU, RSS, pane count, freshness, and state

      Examples:
        | width | visual |
        | normal | resource icon plus compact RSS and pane summary is visible |
        | constrained | only the resource icon remains visible |

    @req-drm-fr-023 @summary
    Scenario: Opening reveals summary, history, sorting, and hierarchy
      Given a successful resource snapshot exists
      When the person opens Resources
      Then global CPU, RSS, physical-memory share, pane count, and update time appear
      And a two-minute aggregate RSS history, sortable headers, and expandable tree appear

    @req-drm-fr-024 @dedup
    Scenario: One process contributes to one proven ownership path
      Given retained workspaces have overlapping reachable ancestry
      When the ownership hierarchy is projected
      Then Tenon host or shared overhead is distinct from workspace, tab, and pane subtrees
      And one stable process identity contributes exactly once

    @req-drm-fr-025 @tty-provenance
    Scenario: Foreground job changes do not retarget pane ownership
      Given a terminal surface has a copied stable TTY name and a changing foreground PID
      When child processes start, background, or change process group
      Then reachable ownership continues from the TTY roots
      And foreground identity only marks presentation

    @req-drm-fr-025 @tty-provenance @unreadable-parent
    Scenario: A pane whose topmost process is unreadable still reports its tree
      Given a terminal whose shell was started through a setuid process the app may not read
      When the sweep chooses where that terminal's tree begins
      Then the topmost process the app could read is the root
      And the shell and every descendant are attributed to the owning pane
      And the unreadable process the app never needed is not reported as a loss

    @req-drm-fr-025 @tty-provenance @unreadable-parent
    Scenario: An unreadable process mid-tree does not hide what is below it
      Given a process inside a pane's tree refuses to be read
      When the sweep walks that terminal
      Then its children are still reached through the kernel's child links
      And only the unreadable process itself is counted as lost

    @req-drm-fr-031 @memory-figure
    Scenario: The memory figure agrees with the operating system
      Given a process the monitor can read
      When its memory is reported
      Then the figure is the physical footprint macOS attributes to that process
      And it is written in the same units macOS itself prints
      So that an operator can check it against Activity Monitor without converting anything

    @req-drm-fr-026 @identity
    Scenario Outline: Ownership uses stable identity and deterministic tie-breaks
      Given one process identity is reachable through <relationship>
      When ownership is resolved
      Then <owner rule>

      Examples:
        | relationship | owner rule |
        | a direct pane TTY | direct TTY ownership wins |
        | roots at different depths | the nearest root wins |
        | roots at the same depth | lexicographically stable slot UUID wins |
        | a reused PID with a new start time | it is a new identity with no inherited counters |

    @req-drm-fr-027 @host-shared
    Scenario Outline: Host and shared processes are not charged to a pane by guesswork
      Given <process kind>
      When the tree is projected
      Then <placement>

      Examples:
        | process kind | placement |
        | Tenon's getpid identity | it appears only as Tenon App overhead |
        | a WebKit, plugin, or helper with no proven exclusive pane | it is shared or unavailable |
        | a terminal descendant | it is not double-counted as host overhead |

    @req-drm-fr-028 @unavailable-owner
    Scenario Outline: Lack of exclusive process ownership remains honest
      Given <condition>
      When the hierarchy updates
      Then <outcome>

      Examples:
        | condition | outcome |
        | a pane has no exclusive OS process | the pane can remain visible with unavailable metrics rather than invented zeros |
        | a process fully reparents outside every reachable root | it leaves terminal ownership |

    @req-drm-fr-029 @feasibility
    Scenario Outline: A metric appears only with proven signed-app semantics
      Given the row may expose <metric>
      When signed-app feasibility is reviewed
      Then <contract>

      Examples:
        | metric | contract |
        | executable name, PID, interval CPU, or RSS | the native field and cost are proven before UI wiring |
        | cumulative or delta disk I/O | shown, because rusage supplies it in the call identity already needs |
        | per-process network receive/send | named absent with a reason, because macOS publishes no per-process counter |

  Rule: Metric and sort semantics never turn missing information into zero

    @req-drm-fr-030 @cpu
    Scenario Outline: CPU is an interval delta rather than a decaying subprocess average
      Given a process has <observation>
      When CPU is formatted
      Then <value>

      Examples:
        | observation | value |
        | its first valid counter | an em dash |
        | positive converted deltas across several cores | the one-decimal value may exceed 100 percent |
        | reset counter, new start identity, or invalid interval | unavailable rather than zero |

    @req-drm-fr-031 @memory
    Scenario Outline: Memory aggregation is exact or unavailable
      Given <memory condition>
      When RSS is projected
      Then <result>

      Examples:
        | memory condition | result |
        | readable bytes | IEC KiB, MiB, or GiB is shown |
        | globally claimed descendants | checked RSS sum contributes once and physical share uses that sum |
        | checked addition overflows | the aggregate is unavailable and the snapshot is partial |

    @req-drm-fr-032 @sorting
    Scenario Outline: Sorting preserves ownership structure
      Given the person selects <header>
      When sort direction is applied
      Then siblings use <order>
      And parents and children are never flattened together

      Examples:
        | header | order |
        | Memory | descending by default and toggled ascending on the next selection |
        | CPU | selected numeric direction with missing values handled explicitly |
        | Name | selected lexical direction |

    @req-drm-fr-033 @history
    Scenario: History grows by aggregate key rather than process count
      Given more than 60 successful samples occur
      When history is retained
      Then Tenon, workspace, tab, and pane keys each keep exactly the newest 60 RSS points
      And raw process rows allocate no history ring

  Rule: Sampling lifecycle preserves the last trustworthy snapshot under churn and failure

    @req-drm-fr-034 @states
    Scenario Outline: Monitor states keep success, absence, and failure distinct
      Given <condition>
      When the monitor projects state
      Then <state>

      Examples:
        | condition | state |
        | no successful snapshot and less than 300 milliseconds elapsed | loading without a flashed skeleton |
        | a complete snapshot exists | ready |
        | sampling succeeded with no local terminal processes | empty |
        | useful rows exist with local read failures | partial |
        | the last good snapshot remains after collector failure | stale |
        | no usable snapshot exists after failure | error with Retry |
        | no monitor surface is visible | paused |

    @req-drm-fr-035 @process-churn
    Scenario Outline: Row-local failures preserve healthy data
      Given <failure>
      When one sweep completes
      Then healthy rows remain visible
      And the affected identity or pane contributes a bounded partial diagnostic

      Examples:
        | failure |
        | ESRCH because a process exited |
        | EPERM or an unreadable record |
        | malformed process metadata |
        | invalid or missing TTY |

    @req-drm-fr-036 @visibility
    Scenario Outline: Periodic demand follows visible monitor surfaces
      Given the monitor is <transition>
      When visibility demand changes
      Then <sampling>

      Examples:
        | transition | sampling |
        | opened | one immediate sample starts and a two-second period begins |
        | closed while another monitor remains | remaining demand continues |
        | the final surface closes | periodic demand stops and the last snapshot is marked paused |
        | reopened | one immediate fresh sample starts |

    @req-drm-fr-037 @coalescing
    Scenario: Ten ticks during a slow sample create one follow-up
      Given one native sample is in flight
      When ten refresh ticks arrive
      Then exactly one pending refresh is coalesced
      And no overlapping sampler call or unbounded queue appears

    @req-drm-fr-038 @retry
    Scenario: Fatal visible failures back off without blocking a deliberate retry
      Given consecutive collector-level failures occur while visible
      When automatic retries are scheduled
      Then delays progress through 2, 4, 8, 16, and 30 seconds
      And one manual Retry bypasses the current delay without adding another in-flight sample

    @req-drm-fr-039 @capacity
    Scenario: A process storm is deterministic and explicitly truncated
      Given more than 4,096 reachable process identities exist
      When one global snapshot is built
      Then traversal stops at the fixed capacity in stable root and breadth-first identity order
      And the useful snapshot is marked partial and truncated

    @req-drm-fr-040 @req-drm-nfr-007 @stale-provenance
    Scenario Outline: Obsolete ownership cannot publish after pane topology changes
      Given a delayed sample captured provenance revision N
      When a pane is <change> at revision N plus 1
      Then the late result is discarded before publication
      And obsolete ownership and history are evicted with at most one replacement request

      Examples:
        | change |
        | closed |
        | moved to another workspace or tab |
        | reopened with another surface |
        | reassigned to another TTY |

    @req-drm-nfr-008 @shutdown
    Scenario: App shutdown reaches telemetry quiescence
      Given the monitor has visible demand and a native sample may be active
      When application shutdown begins
      Then demand is cancelled
      And the coordinator waits only through the bounded native-call boundary before quiescence

  Rule: The monitor navigates accessibly but grants no process-control authority

    @req-drm-fr-041 @focus-pane
    Scenario: Return navigates to the exact owning pane
      Given a visible pane or process row has a proven pane owner
      When the person selects it and presses Return
      Then the existing typed workspace service focuses and reveals that pane
      And no process state changes

    @req-drm-fr-042 @req-drm-nfr-005 @accessibility
    Scenario Outline: Native outline behavior has keyboard and VoiceOver parity
      Given focus is in the Resource Monitor tree
      When the person uses <input>
      Then <outcome>

      Examples:
        | input | outcome |
        | Up or Down | focus moves through visible rows |
        | Left or Right | the row collapses, expands, or focus moves to parent or first child |
        | Home or End | focus moves to the first or last visible row |
        | Space | the selected row toggles expansion |
        | Return | the owning pane is revealed when available |
        | Escape | the popover closes and trigger focus is restored |
        | VoiceOver inspection | level, expansion, name, PID, CPU, RSS, unavailable/shared state, and sort direction are spoken |

    @req-drm-fr-043 @observational
    Scenario Outline: Resource rows expose no management command
      Given a resource row is selected
      When the person or an external principal looks for <action>
      Then the action is absent from the monitor contract

      Examples:
        | action |
        | terminate, throttle, or restart process |
        | close pane or clean workspace |
        | plugin, CLI, agent, palette, or registered-keybinding telemetry access |

    @req-drm-fr-044 @revalidation
    Scenario: Implementation starts from current evidence rather than the old snapshot
      Given the July monitor design and current T-100 criteria differ on network and shared processes
      When delivery begins
      Then current source, native design, domains, boundary inventory, and signed-app feasibility are revalidated
      And unsupported metrics are removed or presented unavailable with a reason
      And the revalidation record states what the old design got wrong rather than quietly correcting it

    @req-drm-nfr-004 @native-design
    Scenario: Orca informs workflow without creating a second Tenon visual language
      Given the Resource Monitor uses Orca as an information-flow reference
      When the native trigger and popover are implemented
      Then Tenon density, typography, semantic color, geometry, components, and states remain normative
      And no feature-local design tokens appear

    @req-drm-nfr-009 @direct
    Scenario: Same-owner telemetry adds no public architecture tax
      Given built-in SwiftUI needs local read-only snapshots and pane navigation
      When the host wires the monitor
      Then it calls typed DIRECT services with a host-private bounded sampling lifecycle
      And no public intent, capability, principal, permission prompt, or tenon path is added without a concrete boundary need

    @req-drm-nfr-010 @compatibility
    Scenario Outline: Native adapters preserve one metric meaning
      Given <adapter condition>
      When process telemetry runs
      Then <compatibility result>

      Examples:
        | adapter condition | compatibility result |
        | Ghostty returns a TTY string | its bytes are copied and the source string is freed exactly once |
        | a supported Darwin API supplies records | native identity and interval semantics are retained |
        | the native API cannot supply a metric | unavailable is shown with no automatic ps fallback |

    @req-drm-nfr-011 @diagnostic-quality
    Scenario: A collection failure says what is stale without leaking process content
      Given a sampler or projection stage fails
      When the UI and log report it
      Then stage, bounded reason, and last-success freshness are visible
      And command arguments, secrets, guessed values, and unbounded per-PID messages are absent

  Rule: Release evidence proves the native boundaries and budgets

    @req-drm-nfr-006 @performance
    Scenario: Release benchmarks keep native collection away from the main actor
      Given a 32-pane fixture owns 1,000 processes
      When a Release benchmark performs 20 warmups and 200 measured iterations
      Then sampling, traversal, and aggregation perform no MainActor work
      And the nearest-rank p95 sample is below 50 milliseconds
      And MainActor publication and binding p95 is below 2 milliseconds

    @req-drm-nfr-012 @evidence
    Scenario: Completion requires one reviewed evidence set rather than static rows
      Given core and hosted tests are green
      When Resource Monitor delivery is reviewed
      Then real Ghostty, UI/accessibility, performance, signed Release, and live multi-workspace receipts share one source SHA
      And no stub-only or partial test subset is called feature completion
