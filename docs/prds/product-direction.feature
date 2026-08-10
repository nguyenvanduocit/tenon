# language: en

@prd-TENON_PRD_000
Feature: Scale human judgment across parallel CLI-agent work without taking over execution
  A technical operator needs to understand, verify, and re-enter several live agent workstreams with less attention cost.
  PRD: product-direction.prd.md

  Rule: Tenon remains a terminal-first supervision layer

    @req-pdr-fr-001 @positioning
    Scenario: Product value is human judgment rather than agent execution volume
      Given several CLI agents can already execute in parallel
      When Tenon describes the problem it owns
      Then it preserves context, directs attention, supports verification, and enables intervention
      And it states that agents scale execution while Tenon scales human judgment

    @req-pdr-fr-002 @operator
    Scenario: One operator supervises several real local workstreams
      Given independently running Codex and Claude CLI sessions work in real repositories
      When the person organizes them in Tenon
      Then each remains a real PTY workstream
      And the person can navigate and inspect more than one without replacing its harness

    @req-pdr-fr-003 @scope-boundary
    Scenario Outline: Agent harness responsibility stays outside Tenon
      Given an agent needs <responsibility>
      When product ownership is evaluated
      Then the CLI harness retains that responsibility
      And Tenon observes or presents the resulting state without redefining its semantics

      Examples:
        | responsibility |
        | planning |
        | spawning and scheduling |
        | command execution |
        | process and session protocol |

    @req-pdr-fr-004 @req-pdr-nfr-001 @terminal-first
    Scenario: A new tab begins as a real native terminal
      Given the person creates a tab
      When its initial pane materializes
      Then one libghostty terminal fills the canvas
      And native keyboard, mouse, clipboard, focus, scale, and resize behavior remains available
      And the application consumes its pinned prebuilt Ghostty framework

    @req-pdr-fr-005 @workspace-model
    Scenario: Shell hierarchy remains simple and spatial
      Given Tenon has one or more directory workspaces
      When the person navigates the shell
      Then the sidebar selects a workspace
      And the workspace owns tabs
      And each tab owns a spatial pane canvas

    @req-pdr-fr-006 @continuity
    Scenario Outline: Spatial organization preserves live identity
      Given a pane owns a live terminal surface
      When the pane is <transition>
      Then the same pane/surface/process identity remains available

      Examples:
        | transition |
        | moved or swapped |
        | resized |
        | hidden by a tab switch |
        | hidden by a workspace switch |

    @req-pdr-fr-006 @relaunch
    Scenario: Relaunch restores structure but not a fictional process
      Given a persisted workspace contained terminal panes before app termination
      When Tenon relaunches
      Then workspace, tab, pane, geometry, content, selection, title, and working-directory placeholders restore fail-soft
      And each terminal materializes lazily as a fresh shell
      And the product does not claim to resurrect the old process

  Rule: Raw evidence remains the authority behind every supervision claim

    @req-pdr-fr-007 @evidence
    Scenario Outline: Navigation aids never replace the raw source
      Given a capsule or view cites <source>
      When the operator asks for supporting evidence
      Then the original source remains directly inspectable
      And generated text is not silently upgraded beyond that source's authority

      Examples:
        | source |
        | terminal transcript position |
        | diff or file |
        | command and exit code |
        | test receipt |

    @req-pdr-fr-008 @pending @five-questions
    Scenario Outline: Supervision answers the operator's decision question
      Given several workstreams changed since the person last looked
      When the person asks <question>
      Then bounded current evidence and attention state provide an answer without rereading every transcript

      Examples:
        | question |
        | what materially changed |
        | what requires judgment now |
        | what the agent claims and what supports it |
        | which work is blocked, drifting, stale, or conflicting |
        | what can safely wait |

    @req-pdr-fr-009 @pending @explicit-state
    Scenario Outline: Typed attention signals remain inspectable
      Given a supported provider emits <state>
      When the Inbox normalizes it
      Then the item preserves state, source, timestamp, and freshness

      Examples:
        | state |
        | needs_input |
        | approval |
        | failed |
        | ready_for_review |
        | completed |

    @req-pdr-fr-010 @pending @inference
    Scenario: Free-form urgency cannot outrank an explicit lifecycle fact
      Given terminal prose sounds urgent but the provider has an authoritative typed state
      When the first supervision wedge ranks attention
      Then the explicit state wins
      And inferred tone remains labelled low-confidence or absent

    @req-pdr-fr-011 @pending @capsule
    Scenario: A since-last-look capsule contains the complete navigation context
      Given one workstream has a material delta
      When its context capsule is assembled
      Then it contains goal, material delta, current claim or blocker or decision, next action, freshness, and exact evidence links

    @req-pdr-fr-012 @req-pdr-nfr-002 @pending @provenance
    Scenario Outline: A material claim carries enough provenance to verify
      Given a capsule contains <claim type>
      When deterministic validation accepts it
      Then source identity, immutable location, content hash, capture time, freshness, and authority level are present
      And <distinction>

      Examples:
        | claim type | distinction |
        | agent text saying tests passed | it remains a reported assertion until a direct receipt entails it |
        | a command receipt with matching exit code and hash | it may be shown as a verified observation |
        | a source changed after capture | the claim is marked stale rather than current |

    @req-pdr-fr-013 @pending @re-entry
    Scenario: An attention item returns to the exact origin
      Given an item cites a live terminal-surface incarnation and evidence location
      When the person selects it
      Then Tenon selects the exact workspace and pane
      And focuses the same live process incarnation when it still exists
      And reveals the relevant transcript, diff, command, or test evidence

    @req-pdr-fr-014 @pending @inbox
    Scenario: The first Inbox stays within a testable human-scale wedge
      Given three to five independent Codex or Claude PTYs are running
      When the Attention Inbox experiment operates
      Then explicit states and capsules cover only those workstreams
      And Terminal remains the exact fallback whenever adapter evidence is absent or degraded

    @req-pdr-fr-015 @agent-lens
    Scenario: Agent Lens is not presented as a completed cross-session product
      Given Agent Lens binds evidence to one live terminal session
      When product status is shown
      Then it is described as current-session evidence projection
      And it is not called the cross-session Attention Inbox or fan-out result

  Rule: Terminal-adjacent surfaces reduce switching without becoming an editor-first IDE

    @req-pdr-fr-016 @adjacent-tools
    Scenario: Common session evidence shares one spatial window
      Given a coding session needs terminals, files, changes, docs, web preview, Kanban, Agent Lens, or a plugin view
      When the person opens those surfaces
      Then they coexist as panes in the same workspace
      And the terminal remains central rather than being replaced by an IDE document model

    @req-pdr-fr-017 @extensibility
    Scenario: The workspace remains useful while adapters stay replaceable
      Given every optional plugin is disabled
      When Tenon opens
      Then the native terminal workspace still functions
      And enabling a plugin can add an adapter or supervision experiment through governed public surfaces

    @req-pdr-fr-018 @ai-writability
    Scenario Outline: Plugin iteration produces a result a model can repair
      Given a developer or AI edits a plugin
      When the host hot reloads it
      Then <outcome>

      Examples:
        | outcome |
        | valid current API usage becomes visible without app restart |
        | an invented API or malformed manifest fails at load with an actionable suggestion |
        | a failed candidate leaves the last good generation active |

    @req-pdr-fr-019 @req-pdr-nfr-012 @architecture-proportionality
    Scenario Outline: Architecture is paid only at a real boundary
      Given behavior is <ownership>
      When its interaction is designed
      Then <route>

      Examples:
        | ownership | route |
        | same-owner host or one plugin's private implementation | a simple typed or local DIRECT call |
        | independently owned finite public operation | one canonical INTENT and shared typed implementation |
        | declarative state, fact, or caller-owned lifetime | its exact CONTRIBUTION, EVENT, or RESOURCE mechanism |

    @req-pdr-fr-020 @req-pdr-nfr-008 @permission-velocity
    Scenario Outline: Ordinary development does not pay repeated permission cost
      Given <plugin state>
      When unchanged manifest-declared behavior reloads and runs
      Then <permission experience>

      Examples:
        | plugin state | permission experience |
        | bundled or trusted development plugin | declared grants apply automatically with no per-call prompt |
        | explicitly enabled local plugin with unchanged authority | its installation review is reused |
        | local plugin materially expanding authority | one review explains the added authority before use |

    @req-pdr-fr-021 @risk-proportionality
    Scenario: A permission interruption must name the risk it buys down
      Given policy proposes per-operation confirmation
      When product review evaluates it
      Then the design names a concrete sensitive, external, destructive, or difficult-to-reverse action
      And the interruption is proportional to that action
      And architectural purity alone is not sufficient justification

    @req-pdr-fr-022 @thin-slice
    Scenario: One verified outcome beats an unused broad framework
      Given a team can either deliver one coherent user-visible vertical slice or a broad speculative abstraction
      When priority is chosen
      Then the coherent slice with source, tests, and visual or interaction evidence wins
      And framework growth waits for a demonstrated repeated need

    @req-pdr-fr-023 @platform-value
    Scenario: Plugin API count is not a customer outcome
      Given an enabling runtime capability ships
      When product value is reported
      Then it is tied to faster safer human judgment or faster validated iteration
      And the number of APIs, permissions, or abstractions is not itself success

  Rule: The Attention Inbox is a falsifiable experiment rather than a roadmap promise

    @req-pdr-fr-024 @req-pdr-nfr-010 @pending @experiment
    Scenario: Evaluation contains representative intervention events
      Given raw Tenon tabs are the control and the Inbox is the treatment
      When at least 20 real interventions are sampled
      Then input requests, failures, review handoffs, completions, and cross-workstream conflicts are represented
      And baseline, method, authority, thresholds, and adjudication are recorded

    @req-pdr-fr-025 @pending @metric
    Scenario: Reorientation improves without hiding blockers
      Given the reviewed intervention sample is complete
      When treatment and control are compared
      Then median context-reorientation time is at least 30 percent lower
      And missed explicit blockers do not increase

    @req-pdr-fr-026 @pending @false-attention
    Scenario: Attention precision stays above the initial guardrail
      Given every Inbox item in the sample is adjudicated
      When false-attention rate is calculated
      Then fewer than 10 percent are false-attention items

    @req-pdr-fr-027 @pending @evidence-error
    Scenario Outline: Evidence integrity allows no accepted material error
      Given the reviewed sample is checked for <error>
      When acceptance is decided
      Then the accepted count is zero

      Examples:
        | error |
        | a material claim whose source anchor, hash, or freshness cannot resolve |
        | a claim shown at an authority level not entailed by its cited evidence |

    @req-pdr-fr-028 @pending @outcome
    Scenario: Faster navigation does not trade away work quality
      Given concurrent workstream count increases during the experiment
      When verified outcomes and review quality are measured
      Then verified outcomes per human-attention minute improve
      And reviewed outcome defects or operator errors do not increase

    @req-pdr-fr-029 @pending @narrowing
    Scenario: Simple signaling wins when capsules add no benefit
      Given reliable notifications perform as well as context capsules on the target outcomes
      When experiment results are reviewed
      Then Tenon narrows the product to reliable agent-aware terminal signaling
      And unnecessary context machinery is not preserved for sunk-cost reasons

    @req-pdr-fr-030 @pending @stop-rule
    Scenario Outline: A failed hypothesis changes the product claim
      Given <failure>
      When the experiment is reviewed
      Then the capsule, inference, or supervision scope is revised or stopped before broad rollout

      Examples:
        | failure |
        | operators still reopen whole transcripts to regain trust |
        | inferred urgency produces excessive false attention |
        | operator errors rise with concurrency despite faster navigation |

    @req-pdr-fr-031 @req-pdr-nfr-011 @status-honesty
    Scenario: Product documentation distinguishes foundation from experiment
      Given a person reads the current status
      When capabilities are enumerated
      Then native workspace, runtime, CLI, palette, automations, Kanban, and current-session Agent Lens are labelled shipped or partial accurately
      And Attention Inbox, capsules, and fan-out measurements are labelled planned until receipts exist

  Rule: Cross-cutting product qualities protect the terminal and evidence loop

    @req-pdr-nfr-003 @pending @summary-privacy
    Scenario: Evidence summarization has no ambient capability
      Given a person explicitly selects a minimum immutable evidence bundle and a configured model provider
      When a summary candidate is requested
      Then the broker is read-only, tool-free, side-effect-free, and secret-free
      And data goes only to the configured provider
      And model output is untrusted until deterministic anchor and freshness validation passes

    @req-pdr-nfr-004 @performance
    Scenario: Pointer and terminal interaction do not rebuild live resources
      Given several terminal surfaces are running
      When the person drags or resizes panes at high frequency
      Then pure geometry computes proposals
      And terminal processes, filesystem state, and content hosts are not reconstructed per pointer update

    @req-pdr-nfr-005 @reliability
    Scenario Outline: Drift fails soft to exact evidence
      Given <drift>
      When Tenon restores or presents the workspace
      Then committed structure and live identities remain as available as possible
      And raw Terminal or source evidence remains the recovery path

      Examples:
        | drift |
        | persistence schema changes |
        | a file or workspace path disappears |
        | a plugin or provider becomes unavailable |
        | an evidence anchor becomes stale |

    @req-pdr-nfr-006 @accessibility
    Scenario: Supervision and permission outcomes are not pointer-only or color-only
      Given an item, pane, command, status, or authority review is operable by pointer
      When a keyboard or VoiceOver user performs the same job
      Then focus, labels, actions, state meaning, and observable outcome remain equivalent

    @req-pdr-nfr-007 @native-design
    Scenario: New product surfaces remain recognizably Tenon and macOS
      Given an Inbox, capsule, permission review, or adjacent pane is designed
      When it renders in the host
      Then density, typography, semantic color, geometry, components, and interaction follow docs/designs.md
      And no feature-local visual token system is introduced

    @req-pdr-nfr-008 @pending @velocity-measurement
    Scenario: Developer-loop friction is measured like product performance
      Given trusted plugin changes are made across representative tasks
      When edit-to-visible-result time and manual permission/architecture steps are recorded
      Then the baseline and distribution are retained
      And any regression requires a named risk or user outcome proportional to its cost

    @req-pdr-nfr-009 @changeability
    Scenario: Replacing one experiment preserves unrelated workspace state
      Given an agent adapter or supervision projection is replaced
      When its generation or presentation changes
      Then pane geometry, terminal surface identity, workspace catalog, and unrelated plugins remain intact

    @req-pdr-nfr-010 @measurement-integrity
    Scenario: Open-agent count is not accepted as success
      Given a release can display more simultaneous agents
      When product success is evaluated
      Then the claim requires verified outcomes, human-attention cost, quality, sample, method, and error measures
      And agent count alone is rejected
