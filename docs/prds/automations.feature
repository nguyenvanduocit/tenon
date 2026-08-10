# language: en

@prd-TENON_PRD_013
Feature: Author, schedule, inspect, and supervise bounded JavaScript automations
  Operators need durable workflows that retain plugin authority and visible evidence.
  PRD: automations.prd.md

  Rule: An automation is an ordinary plugin plus a declarative wall-clock schedule

    @req-au-fr-001 @req-au-fr-002 @req-au-nfr-007
    Scenario: Scheduling adds no privileged automation runtime
      Given plugin JavaScript declares schedules and intent uses
      When a due occurrence fires
      Then the manifest is CONTRIBUTION and automation.fired is an owner-scoped EVENT
      And subsequent work uses ordinary intents under the same plugin principal and generation
      And no schedule-specific public tenon member or core intent exists

    @req-au-fr-003 @req-au-fr-004 @validation
    Scenario Outline: Manifest schedule grammar fails closed
      Given a schedule declares <shape>
      When the manifest decodes
      Then <outcome>

      Examples:
        | shape | outcome |
        | one unique ID and every from 1m through 7d | it is accepted |
        | one unique ID and zero-padded daily HH:mm | it is accepted in machine-local time |
        | both every and daily or neither | it is refused |
        | sub-minute, over-7d, malformed daily, duplicate ID, or ninth schedule | it is refused |
        | valid optional grace from 1m through 7d | that grace is retained |

    @req-au-fr-005 @req-au-nfr-001 @firing
    Scenario Outline: Due computation is deterministic and never catches up as a burst
      Given a schedule's nextDue is behind now by <age>
      When the scheduler ticks twice at the same now
      Then <outcome>

      Examples:
        | age | outcome |
        | within grace | only the latest missed occurrence fires once |
        | beyond grace | nothing fires and phase rearms from now |

    @req-au-fr-006 @payload
    Scenario Outline: Firing facts preserve exact trigger evidence
      Given a firing is caused by <cause>
      When it is delivered
      Then payload contains scheduleId, ISO scheduledFor, late, and trigger <trigger>

      Examples:
        | cause | trigger |
        | the tick loop | scheduled |
        | Run Now | manual |

    @req-au-fr-007 @req-au-nfr-004 @reconcile
    Scenario Outline: Reconcile preserves only valid current ownership
      Given a plugin schedule is <change>
      When host lifecycle reconciles
      Then <outcome>

      Examples:
        | change | outcome |
        | hot-reloaded without spec changes | its phase is preserved |
        | changed | phase recomputes from reconcile time |
        | disabled or unloaded | it no longer schedules |
        | retired during an in-flight batch | no callback enters the retired context |

    @req-au-fr-008 @req-au-nfr-003 @authority
    Scenario: A firing carries no authority
      Given an untrusted authored automation declares a privileged action
      When scheduled or manual firing reaches its handler
      Then the action still needs declared use, capability, policy, consent, and deadline
      And nobody at the window causes unanswered consent to expire rather than run silently

  Rule: Canvas exposes operational truth without claiming business success

    @req-au-fr-009 @global-pause
    Scenario: Global enablement pauses only scheduled delivery
      Given an older preferences document lacks the global automation field
      When settings loads and the person later disables scheduling
      Then the preference defaults on and persists the new value
      And plugins remain loaded while due scheduled events are suppressed
      And Run Now remains available

    @req-au-fr-010 @pause
    Scenario: Per-schedule pause advances without replay
      Given one schedule is paused across reload, disable, and relaunch
      When occurrences pass and the person resumes it
      Then skipped work is not replayed
      And its declaration and Run Now remain available

    @req-au-fr-011 @req-au-fr-012 @req-au-nfr-005 @canvas
    Scenario Outline: Canvas distinguishes active, absent, and anomalous declarations
      Given a plugin is <state>
      When Canvas search or All, Attention, Paused filters render it
      Then <outcome>

      Examples:
        | state | outcome |
        | enabled and loaded | owner, cadence, next due, grace, and activity are inspectable |
        | enabled but unloaded or failed | its declaration remains with an attention reason |
        | disabled | its schedule leaves Canvas until re-enabled |

    @req-au-fr-013 @run-now
    Scenario: Run Now uses the same delivery path without shifting phase
      Given a schedule has a known nextDue
      When the person presses Run Now
      Then exactly one manual automation.fired reaches the owner through the normal emit site
      And nextDue is unchanged

    @req-au-fr-014 @req-au-nfr-002 @req-au-nfr-006 @history
    Scenario: Recent history is bounded delivery evidence
      Given more than 128 scheduled and manual attempts occur across plugin reloads
      When Canvas shows history
      Then only the newest 128 remain
      And each row names exact schedule, instant, trigger, lateness, and delivered or dropped
      And copy says Recent and never calls delivery business success

    @req-au-fr-015 @architecture
    Scenario: Host UI reads automation state directly
      Given the person opens Canvas and runs a schedule
      When host-native controls act
      Then they call typed scheduler, host, and workspace services DIRECT
      And the plugin sees only the existing owner-scoped firing EVENT

  Rule: Single-file and AI authoring preserve declaration before evaluation

    @req-au-fr-016 @single-file
    Scenario: A leading embedded manifest produces an ordinary plugin
      Given a top-level JavaScript file opens with one valid tenon-manifest block
      When inventory discovery and hot reload run
      Then the shared manifest decoder validates it before evaluation
      And activation and retirement cannot distinguish it from directory packaging

    @req-au-fr-017 @single-file
    Scenario Outline: A JavaScript file is classified honestly
      Given a top-level file <condition>
      When discovery scans it
      Then <outcome>

      Examples:
        | condition | outcome |
        | has code before the header or a broken claimed header | a diagnostic names the file and defect |
        | has no header | it is ignored as a scratch script |
        | duplicates a directory plugin ID | normal mixed-inventory identity refusal applies |

    @req-au-fr-018 @inventory
    Scenario: Authored code lands in durable untrusted storage
      Given an agent writes an automation
      When the host selects its authoring root
      Then it uses the writable user-plugin inventory
      And it cannot modify or displace a bundled identity
      And its location alone grants no consent

    @req-au-fr-019 @authoring
    Scenario: Create with AI moves focus from Settings to one authoring pane
      Given Settings shows Automation in an empty or populated state
      When the person chooses Create with AI
      Then a fresh terminal tab opens at the real writable plugin root
      And Settings closes and the terminal receives focus

    @req-au-fr-020 @guide
    Scenario: The guide teaches a verifiable minimal contract
      Given the host knows the real writable inventory path
      When it builds the authoring prompt
      Then the prompt includes that path, leading header, schedule grammar, firing payload, CLI discovery, consent warning, interview-first instruction, and Run Now verification

    @req-au-fr-021 @security
    Scenario: Hostile guide content cannot become shell syntax
      Given the prompt and plugin root contain spaces, quotes, substitutions, backticks, and newlines
      When Claude is launched
      Then the complete guide is one POSIX-quoted argument
      And none of its content executes as a separate shell token

  Rule: Supervised agent fleets are bounded caller-local intent composition

    @req-au-fr-022 @req-au-nfr-003 @agents-run
    Scenario: Agent run cannot launder authority through a broker
      Given a plugin calls tenon.agents.run
      When the helper opens, waits, and reads a pane
      Then every underlying intent uses the caller's own principal, manifest, scope, and deadline
      And no agent-run provider holds broader grants

    @req-au-fr-023 @agents-run
    Scenario: Command arguments remain data and the pane remains observable
      Given an argument contains quotes, command substitution, or backticks
      When agents.run creates a visible terminal pane
      Then command and every argument are quoted per token
      And success returns that pane ID and bounded transcript

    @req-au-fr-024 @req-au-nfr-002 @agents-run
    Scenario Outline: Waiting is finite under both sender shapes
      Given agents.run uses <sender>
      When completion does not arrive within one 55-second wait slice
      Then it retries only within <budget>
      And expiry returns a typed timeout without reading an incomplete transcript

      Examples:
        | sender | budget |
        | tenon.intents | the call's timeoutMs or ten-minute default |
        | a handler call | the invocation deadline and cancellation |

    @req-au-fr-025 @scrollback
    Scenario Outline: Scrollback invalidation never mixes generations
      Given cursor paging is invalidated <count>
      When agents.run collects the transcript
      Then <outcome>

      Examples:
        | count | outcome |
        | once | the walk restarts from the beginning and succeeds cleanly |
        | twice | scrollback-unstable fails typed without a mixed transcript |

    @req-au-fr-026 @parallel
    Scenario: JavaScript owns workflow structure under runtime bounds
      Given an automation uses Promise.all, loops, branches, pipelines, and retries
      When it dispatches work
      Then ordinary JavaScript controls data flow
      And the generation cannot exceed 256 in-flight outbound intents

    @req-au-fr-027 @fleet-example
    Scenario: The fleet example stays executable but opt-in
      Given examples/fleet-review is loaded into a test host or copied by a user
      When its command runs
      Then three visible reviewer panes execute in parallel
      And their transcripts aggregate into one verdict
      And the example is not installed into every user's palette by default

  Rule: Installed evidence closes the remaining product boundary

    @req-au-fr-028 @req-au-nfr-008 @pending @manual
    Scenario Outline: Installed workflows verify what headless seams cannot
      Given an installed Tenon app and a true supported agent provider
      When the reviewer performs <flow>
      Then the complete behavior is observed without assuming component composition

      Examples:
        | flow |
        | watch Canvas due state, Run Now, and a manual history row |
        | Create with AI and produce a working hot-reloaded script |
        | run a command fast enough to finish near the open-to-wait boundary |

    @req-au-nfr-004 @policy-epoch
    Scenario: A policy change invalidates only the intended in-flight delivery scope
      Given a firing batch contains several schedules
      When one schedule is paused during delivery
      Then its owner-scoped epoch prevents stale delivery for that schedule
      And unrelated schedules continue unless global enablement changed

    @req-au-nfr-005 @accessibility
    Scenario: Canvas and authoring remain native and operable
      Given keyboard, VoiceOver, increased contrast, or a narrow pane is in use
      When schedules, filters, inspector, history, and actions render
      Then every state and action has a native label and focus path
      And status does not depend only on color
